#!/usr/bin/env ruby

require_relative "simplenetworkjob"

require "qbuffer"
require "qjsondocument"

include OCC

class SimpleNetworkJob
  def initialize(account, root_url, path, verb, req, parent)
    super(account, root_url, path, parent)
    @request = req
    @verb = verb
  end

  def initialize_with_parent(account, root_url, path, verb, parent)
    super(account, root_url, path, verb, nil, parent)
  end

  def initialize_with_parent_2(account, root_url, path, verb, arguments, req, parent)
    super(account, root_url, path, verb, req, parent)

    unless ["GET", "PUT", "POST", "DELETE", "HEAD", "PATCH"].contains(verb)
      raise
    end

    if !arguments.is_empty
      args = QUrlQuery.new

      arguments.each do |item|
        args.add_query_item(
          QString.from_utf8(QUrl.to_percent_encoding(item.first)),
          QString.from_utf8(QUrl.to_percent_encoding(item.second))
        )
      end

      if verb == "POST" || verb == "PUT" || verb == "PATCH"
        @request.set_header(:content_type_header, "application/x-www-form-urlencoded; charset=UTF-8")
        @body = args.query(:fully_encoded).to_utf8
        @device = QBuffer.new(@body)
      else
        set_query(args)
      end
    end
  end

  def initialize_with_parent_3(account, root_url, path, verb, arguments, req, parent)
    super(account, root_url, path, verb, QJsonDocument.new(arguments).to_json, req, parent)
    @request.set_header(:content_type_header, "application/json")
  end

  def initialize_with_parent_4(account, root_url, path, verb, request_body, req, parent)
    super(account, root_url, path, verb, req, parent)
    @device = request_body
  end

  def initialize_with_parent_5(account, root_url, path, verb, request_body, req, parent)
    super(account, root_url, path, verb, nil, req, parent)
    @body = request_body
    @device = QBuffer.new(@body)
  end

  def finalize
  end

  def start
    unless !@verb.is_empty
      raise
    end

    send_request(@verb, @request, @device)
    AbstractNetworkJob.start
  end

  def add_new_reply_hook(hook)
    @reply_hooks.push_back(hook)
  end

  def finished
    if @device
      @device.close
    end

    if body
      body.close
    end
  end

  def new_reply_hook(reply)
    @reply_hooks.each do |hook|
      hook.call(reply)
    end
  end
end
