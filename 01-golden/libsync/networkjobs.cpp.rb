#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
# Copyright (C) by Daniel Molkentin <danimo@owncloud.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
# for more details.
#

require_relative "networkjobs"

require "qbuffer"
require "qxmlstreamreader"
require_relative "account"

include std::chrono_literals

module OCC
  class RequestEtagJob
    def initialize(account, root_url, path, parent)
      super(account, root_url, path, :zero, parent)
      set_properties(["getetag"])

      connect(this, PropfindJob.directory_listing_iterated, this) do |_, value|
        @etag = Utility.normalize_etag(value.value("getetag"))

        if !!@etag.is_empty
          abort
        end
      end
    end

    def etag
      return @etag
    end
  end

  class MkColJob
    def initialize(account, url, path, extra_headers, parent)
      super(account, url, path, parent)
      @extra_headers = extra_headers
    end

    def start
      req = QNetworkRequest.new
      req.set_raw_header("Content-Length", "0")
      it = @extra_headers.const_begin

      while it != @extra_headers.const_end
        req.set_raw_header(it.key, it.value)
        it += 1
      end

      send_request("MKCOL", req)
      AbstractNetworkJob.start
    end

    def finished
      Log.info("sync.networkjob.mkcol") { "MKCOL of #{reply.request.url} FINISHED WITH STATUS #{reply_status_string}" }

      if reply.error != :no_error
        finished_with_error(reply)
      else
        finished_without_error
      end
    end

    def read_contents_as_string(reader)
      result = ""
      level = 0

      loop do
        type = reader.read_next

        if type == :start_element
          level += 1
          result += "<" + reader.name.to_string + ">"
        elsif type == :characters
          result += reader.text
        elsif type == :end_element
          level -= 1

          if level < 0
            break
          end

          result += "</" + reader.name.to_string + ">"
        end

        unless !reader.at_end
          break
        end
      end

      return result
    end
  end

  class LsColXMLParser
    def initialize
    end

    def parse(xml, sizes, expected_path)
      reader = QXmlStreamReader.new(xml)
      reader.add_extra_namespace_declaration(QXmlStreamNamespaceDeclaration.new("d", "DAV:"))
      folders = []
      current_href = ""

      current_tmp_properties = Hash.new do |hash, key|
        hash[key] = QString.new
      end

      current_http200_properties = Hash.new do |hash, key|
        hash[key] = QString.new
      end

      current_props_are_valid = false
      inside_propstat = false
      inside_prop = false
      inside_multi_status = false

      while !reader.at_end
        type = reader.read_next
        name = reader.name.to_string

        if type == :start_element && reader.namespace_uri == "DAV:"
          if name == "href"
            href_string = QString.from_utf8(QByteArray.from_percent_encoding(reader.read_element_text.to_utf8))

            if !href_string.starts_with(expected_path)
              Log.warn("sync.networkjob.propfind") { "Invalid href #{href_string} expected starting with #{expected_path}" }

              return false
            end

            current_href = href_string
          elsif name == "response"
            nil
          elsif name == "propstat"
            inside_propstat = true
          elsif name == "status" && inside_propstat
            http_status = reader.read_element_text

            if (
              http_status.starts_with("HTTP/1.1 200") ||
              http_status.starts_with("HTTP/1.1 425")
            )
              current_props_are_valid = true
            else
              current_props_are_valid = false
            end
          elsif name == "prop"
            inside_prop = true

            next
          elsif name == "multistatus"
            inside_multi_status = true

            next
          end
        end

        if type == :start_element && inside_propstat && inside_prop
          property_content = read_contents_as_string(reader)

          if (
            name == "resourcetype" &&
            property_content.contains("collection")
          )
            folders.append(current_href)
          elsif name == "size"
            ok = false
            s = property_content.to_long_long(ok)

            if ok && sizes
              sizes.insert(current_href, s)
            end
          end

          current_tmp_properties.insert(reader.name.to_string, property_content)
        end

        if type == :end_element
          if reader.namespace_uri == "DAV:"
            if reader.name == "response"
              if current_href.ends_with("/")
                current_href.chop(1)
              end

              directory_listing_iterated(current_href, current_http200_properties)
              current_href.clear
              current_http200_properties.clear
            elsif reader.name == "propstat"
              inside_propstat = false

              if current_props_are_valid
                current_http200_properties = current_tmp_properties
              end

              current_props_are_valid = false
            elsif reader.name == "prop"
              inside_prop = false
            end
          end
        end
      end

      if reader.has_error
        Log.warn("sync.networkjob.propfind") { "ERROR #{reader.error_string} #{xml}" }

        return false
      elsif !inside_multi_status
        Log.warn("sync.networkjob.propfind") { "ERROR no WebDAV response? #{xml}" }

        return false
      else
        directory_listing_subfolders(folders)
        finished_without_error
      end

      return true
    end
  end

  class PropfindJob
    def initialize(account, url, path, depth, parent)
      super(account, url, path, parent)
      @depth = depth
      set_priority(:high_priority)
    end

    def set_properties(properties)
      @properties = properties
    end

    def properties
      return @properties
    end

    def start
      req = QNetworkRequest.new
      req.set_raw_header("Depth", QByteArray.number(@depth))
      req.set_raw_header("Prefer", "return=minimal")

      if @properties.is_empty
        Log.warn("sync.networkjob.propfind") { "Propfind with no properties!" }
      end

      data = ""
      stream = QTextStream.new(data, :write_only)
      stream.set_encoding(:utf8)
      stream << "<?xml version=\"1.0\" encoding=\"utf-8\"?>" "<d:propfind xmlns:d=\"DAV:\">" "<d:prop>"

      @properties.each do |prop|
        col_idx = prop.last_index_of(":")

        if col_idx >= 0
          stream << "<" << prop.mid(col_idx + 1) << " xmlns=\"" << prop.left(col_idx) << "\"/>"
        else
          stream << "<d:" << prop << "/>"
        end
      end

      stream << "</d:prop>" "</d:propfind>\n"
      buf = QBuffer.new
      buf.set_data(data)
      buf.open(:read_only)
      send_request("PROPFIND", req, buf)
      AbstractNetworkJob.start
    end

    def finished
      Log.info("sync.networkjob.propfind") { "LSCOL of #{reply.request.url} FINISHED WITH STATUS #{reply_status_string}" }
      content_type = reply.header(:content_type_header).to_string

      if http_status_code == 207
        if content_type.contains("application/xml; charset=utf-8")
          parser = LsColXMLParser.new
          connect(parser, LsColXMLParser.directory_listing_subfolders, this, PropfindJob.directory_listing_subfolders)
          connect(parser, LsColXMLParser.directory_listing_iterated, this, PropfindJob.directory_listing_iterated)
          connect(parser, LsColXMLParser.finished_without_error, this, PropfindJob.finished_without_error)

          if @depth == :zero
            counter = 0

            connect(parser, LsColXMLParser.directory_listing_iterated, this) do |name, _|
              counter += 1

              if counter == 1
                disconnect(
                  parser,
                  LsColXMLParser.directory_listing_iterated,
                  this,
                  PropfindJob.directory_listing_iterated
                )
              else
                Log.error("sync.networkjob.propfind") { "Received superfluous directory listing for depth 0 propfind #{counter} Path: #{name}" }
              end
            end
          end

          expected_path = reply.request.url.path

          if !parser.parse(reply.read_all, @sizes, expected_path)
            finished_with_error
          end
        else
          Log.warn("sync.networkjob.propfind") { "Unexpected ContentTypeHeader: #{content_type}" }
          finished_with_error
        end
      else
        finished_with_error
      end
    end

    def sizes
      return @sizes
    end
  end

  class EntityExistsJob
    def initialize(account, root_url, path, parent)
      super(account, root_url, path, parent)
    end

    def start
      send_request("HEAD")
      AbstractNetworkJob.start
    end

    def finished
      exists(reply)
    end

    def fetch_private_link_url(account, base_url, remote_path, target, target_fun)
      if account.capabilities.private_link_property_available
        job = PropfindJob.new(account, base_url, remote_path, :zero, target)
        job.set_properties(["http://owncloud.org/ns:privatelink"])
        job.set_timeout(10)

        QObject.connect(job, PropfindJob.directory_listing_iterated, target) do |_, result|
          private_link_url = result["privatelink"]

          if !private_link_url.is_empty
            target_fun.call(QUrl.new(private_link_url))
          end
        end

        job.start
      end
    end
  end
end
