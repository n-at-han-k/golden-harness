#!/usr/bin/env ruby

require_relative "credentialmanager"

require_relative "account"
require_relative "configfile"

require_relative "common/asserts"
require_relative "common/chronoelapsedtimer"

require "qcoreapplication"
require "qcborvalue"
require "qloggingcategory"
require "qtimer"

require "chrono"

include std::chrono_literals
include OCC

class CredentialManager
  TIEMOUT_C = 5
  def initialize(acc)
    super(acc)
    @account = acc
  end

  def credential_key_c
    return "#{QCoreApplication.application_name}_credentials"
  end

  def account_key(acc)
    unless !acc.url.is_empty
      raise
    end

    return "#{credential_key_c}:#{acc.url.host}:#{acc.uuid.to_string(:without_braces)}"
  end

  def scope(manager)
    if manager.account
      return account_key(manager.account)
    else
      return credential_key_c
    end
  end

  def scoped_key(manager, key)
    return scope(manager) + ":" + key
  end

  def initialize_with_parent(parent)
    super(parent)
  end

  def get(key)
    Log.info("sync.credentials.manager") { "get #{scoped_key(this, key)}" }
    out = CredentialJob.new(this, key)
    out.start

    return out
  end

  def set(key, data)
    unless !data.is_null
      raise
    end

    Log.info("sync.credentials.manager") { "set #{scoped_key(this, key)}" }
    write_job = QKeychain::WritePasswordJob.new(QCoreApplication.application_name)
    write_job.set_key(scoped_key(this, key))
    timer = QTimer.new(write_job)
    timer.set_interval(TIEMOUT_C)
    elapsed_timer = ChronoElapsedTimer.new
    connect(timer, QTimer.timeout, write_job) { Log.warn("sync.credentials.manager") { "set #{write_job.key} has not yet finished. #{elapsed_timer}" } }

    connect(write_job, QKeychain::WritePasswordJob.finished, this) do
      if write_job.error == :no_error
        Log.info("sync.credentials.manager") { "added #{write_job.key} after #{elapsed_timer}" }
        credentials_list.set_value(key, true)
        credentials_list.sync
      else
        Log.warn("sync.credentials.manager") { "Failed to set: #{write_job.key} #{write_job.error_string} after #{elapsed_timer}" }
      end
    end

    write_job.set_binary_data(QCborValue.from_variant(data).to_cbor)
    write_job.start
    timer.start

    return write_job
  end

  def remove(key)
    unless contains(key)
      raise
    end

    credentials_list.remove(key)
    credentials_list.sync
    Log.info("sync.credentials.manager") { "del #{scoped_key(this, key)}" }
    keychain_job = QKeychain::DeletePasswordJob.new(QCoreApplication.application_name)
    keychain_job.set_key(scoped_key(this, key))

    connect(keychain_job, QKeychain::DeletePasswordJob.finished, this) do
      unless keychain_job.error != :entry_not_found
        raise
      end

      if keychain_job.error == :no_error
        Log.info("sync.credentials.manager") { "removed #{scoped_key(this, key)}" }
      else
        Log.warn("sync.credentials.manager") { "Failed to remove: #{scoped_key(this, key)} #{keychain_job.error_string}" }
      end
    end

    keychain_job.start

    return keychain_job
  end

  def clear(group)
    unless @account || !group.is_empty
      raise
    end

    keys = known_keys(group)
    out = []
    out.reserve(keys.size)

    keys.each do |key|
      out << remove(key)
    end

    return out
  end

  def account
    return @account
  end

  def contains(key)
    return credentials_list.contains(key)
  end

  def known_keys(group)
    if group.is_empty
      return credentials_list.all_keys
    end

    credentials_list.begin_group(group)
    keys = credentials_list.all_keys
    out = []
    out.reserve(keys.size)

    keys.each do |k|
      out.append(group + "/" + k)
    end

    credentials_list.end_group

    return out
  end

  def credentials_list
    if !@credentials_list
      @credentials_list = ConfigFile.make_q_settings_pointer
      @credentials_list.begin_group("Credentials/" + scope(this))
    end

    return @credentials_list
  end
end

class CredentialJob
  def initialize(parent, key)
    super(parent)
    @key = key
    @parent = parent
    connect(this, CredentialJob.finished, this, CredentialJob.delete_later)
  end

  def error_string
    return @error_string
  end

  def data
    return @data
  end

  def error
    return @error
  end

  def start
    if !@parent.contains(@key)
      @error = :entry_not_found
      Log.debug("sync.credentials.manager") { "We don't know #{@key} skipping retrieval from keychain" }
      QTimer.single_shot(0, this, CredentialJob.finished)

      return
    end

    @job = QKeychain::ReadPasswordJob.new(QCoreApplication.application_name)
    @job.set_key(scoped_key(@parent, @key))

    connect(@job, QKeychain::ReadPasswordJob.finished, this) do
      if (
        @retry_on_key_chain_error &&
        (
          @job.error == :no_backend_available ||
          @job.error == :other_error
        )
      )
        Log.info("sync.credentials.manager") { "Backend unavailable (yet?) Retrying in a few seconds. #{@job.error_string}" }
        QTimer.single_shot(10, this, CredentialJob.start)
        @retry_on_key_chain_error = false
      end

      unless @job.error != :entry_not_found
        raise
      end

      if @job.error == :no_error
        error = QCborParserError.new
        obj = QCborValue.from_cbor(@job.binary_data, error)

        if error.error != :no_error
          @error = :other_error
          @error_string = "Failed to parse credentials #{error.error_string}"

          return
        end

        @data = obj.to_variant

        unless @data.is_valid
          raise
        end
      else
        Log.warn("sync.credentials.manager") { "Failed to get password #{scoped_key(@parent, @key)} #{@job.error_string}" }
        @error = @job.error
        @error_string = @job.error_string
      end

      finished
    end

    @job.start
  end

  def key
    return @key
  end
end
