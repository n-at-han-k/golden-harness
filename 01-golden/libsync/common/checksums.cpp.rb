#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
#

require_relative "common/checksums"
require_relative "asserts"
require_relative "common/chronoelapsedtimer"
require_relative "common/utility"
require_relative "filesystembase"

require "qcoreapplication"
require "qcryptographichash"
require "qloggingcategory"
require "qscopeguard"
require "qtconcurrentrun"

require "zlib"

module OCC
  class ChecksumHeader
    BUFSIZE = (500 * 1024)
    def initialize(type, checksum)
      @checksum_type = type
      @checksum = checksum
    end

    def parse_checksum_header(header)
      if header.is_empty
        return nil
      end

      out = ChecksumHeader.new
      idx = header.index_of(":")

      if idx < 0
        out.error = QCoreApplication.translate("ChecksumHeader", "The checksum header is malformed: %1").arg(QString.from_utf8(header))
      else
        out.checksum_type = CheckSums.from_byte_array(header.left(idx))

        if out.checksum_type == :parse_error
          out.error = QCoreApplication.translate(
            "ChecksumHeader",
            "The checksum header contained an unknown checksum type '%1'"
          ).arg(QString.from_utf8(header.left(idx)))
        end

        out.checksum = header.mid(idx + 1)
      end

      if !out.is_valid
        Log.debug("sync.checksums.header") { "Failed to parse #{header} #{out.error}" }
      end

      return out
    end

    def calc_adler32(device)
      if device.size == 0
        return ""
      end

      buf = QByteArray.new(BUFSIZE, :uninitialized)
      adler = adler32(0, nil, 0)
      size = nil

      while !device.at_end
        size = device.read(buf.data, BUFSIZE)

        if size > 0
          adler = adler32(adler, buf.data, size)
        end
      end

      return QByteArray.number(adler, 16)
    end

    def make_checksum_header
      if !is_valid
        return nil
      end

      return Utility.enum_to_string(@checksum_type).to_utf8 + ":" + @checksum
    end

    def type
      return @checksum_type
    end

    def checksum
      return @checksum
    end

    def is_valid
      return (
        @checksum_type != :none &&
        @checksum_type != :parse_error &&
        !@checksum.is_empty
      )
    end

    def error
      return @error
    end

    def ==(other)
      return (
        @checksum_type == other.checksum_type &&
        @checksum == other.checksum
      )
    end

    def !=(other)
      return !(this == other)
    end

    def find_best_checksum(_checksums)
      if @checksums.is_empty
        return nil
      end

      i = lambda do
        :all.each do |algo|
          i = checksums.index_of(algo.second.data)

          if i != -1
            return i
          end
        end

        return -1
      end

      i.call

      if i != -1
        last_slash = @checksums.index_of(" ", i)

        if last_slash == -1
          last_slash = @checksums.index_of("<", i)
        end

        return @checksums.mid(i, last_slash - i)
      end

      Log.warn("sync.checksums") { "Failed to parse #{@checksums}" }

      return nil
    end
  end

  class ComputeChecksum
    def initialize(parent)
      super(parent)
    end

    def finalize
    end

    def set_checksum_type(type)
      unless type != :none && type != :parse_error
        raise
      end

      @checksum_type = type
    end

    def checksum_type
      return @checksum_type
    end

    def start(file_path)
      Log.info("sync.checksums") { "Computing #{checksum_type} checksum of #{file_path} in a thread" }
      start_impl(QFile.new(file_path))
    end

    def start_with_device(device)
      unless device
        raise
      end

      Log.info("sync.checksums") { "Computing #{checksum_type} checksum of device #{device.get} in a thread" }

      unless !device.parent
        raise
      end

      start_impl(device)
    end

    def start_impl(device)
      connect(@watcher, QFutureWatcherBase.finished, this, ComputeChecksum.slot_calculation_done, :unique_connection)
      shared_device = QSharedPointer.new(device.release)
      type = checksum_type

      @watcher.set_future(QtConcurrent.run do
        if !shared_device.open(:read_only)
          file = qobject_cast < QFile > (shared_device.data)

          if file
            Log.warn("sync.checksums") { "Could not open file #{file.file_name} for reading to compute a checksum #{file.error_string}" }
          else
            Log.warn("sync.checksums") {
              "Could not open device #{shared_device.data} for reading to compute a checksum" \
                "#{shared_device.error_string}"
            }
          end

          return ""
        end

        result = ComputeChecksum.compute_now(shared_device.data, type)
        shared_device.close

        return result
      end)
    end

    def compute_now_on_file(file_path, checksum_type)
      file = QFile.new(file_path)

      if !file.open(:read_only)
        Log.warn("sync.checksums") { "Could not open file #{file_path} for reading and computing checksum #{file.error_string}" }

        return ""
      end

      return compute_now(file, checksum_type)
    end

    def compute_now(device, algorithm)
      log = q_scope_guard do
        file = qobject_cast < QFile > (device)

        if file
          Log.debug("sync.checksums") { "Finished #{algorithm} computation for #{file.file_name} #{timer}" }
        else
          Log.debug("sync.checksums") { "Finished #{algorithm} computation for #{device} #{timer}" }
        end
      end

      case algorithm
      when :sha3_256, :sha256, :sha1, :md5
        crypto = QCryptographicHash.new(algorithm)

        if crypto.add_data(device)
          return crypto.result.to_hex
        end

        Log.warn("sync.checksums") { "Failed to compoute checksum #{Utility.enum_to_string(algorithm)}" }

        return nil
      when :adler32
        return calc_adler32(device)
      when :dummy_for_tests
        return "0x1"
      when :parse_error
        return nil
      when :none
        raise
      end

      raise
    end

    def slot_calculation_done
      checksum = @watcher.future.result

      if !checksum.is_null
        done(@checksum_type, checksum)
      else
        done(:parse_error, "")
      end
    end
  end

  class ValidateChecksumHeader
    def initialize(parent)
      super(parent)
    end

    def prepare_start(checksum_header)
      if checksum_header.is_empty
        validated(:parse_error, "")

        return nil
      end

      @expected_checksum = ChecksumHeader.parse_checksum_header(checksum_header)

      if !@expected_checksum.is_valid
        Log.warn("sync.checksums") { "Checksum header malformed: #{checksum_header}" }
        validation_failed(@expected_checksum.error)

        return nil
      end

      calculator = ComputeChecksum.new(this)
      calculator.set_checksum_type(@expected_checksum.type)
      connect(calculator, ComputeChecksum.done, this, ValidateChecksumHeader.slot_checksum_calculated)

      return calculator
    end

    def start(file_path, checksum_header)
      calculator = prepare_start(checksum_header)

      if calculator
        calculator.start(file_path)
      end
    end

    def start_with_checksum_header(device, checksum_header)
      calculator = prepare_start(checksum_header)

      if calculator
        calculator.start(device)
      end
    end

    def slot_checksum_calculated(checksum_type, checksum)
      if @expected_checksum.type == :parse_error
        validation_failed(@expected_checksum.error)

        return
      end

      if checksum != @expected_checksum.checksum
        validation_failed("The downloaded file does not match the checksum, it will be resumed. '#{QString.from_utf8(@expected_checksum.checksum)}' != '#{QString.from_utf8(checksum)}'")

        return
      end

      validated(checksum_type, checksum)
    end
  end
end
