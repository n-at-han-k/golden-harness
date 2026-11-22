#!/usr/bin/env ruby
#
# Copyright (C) by Markus Goetz <markus@woboq.com>
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

require_relative "libsync/networkjobs/getfilejob"
require_relative "owncloudpropagator"
require_relative "propagateupload"

require "qloggingcategory"
require "qtimer"
require "qobject"

module OCC
  class BandwidthManager
    RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC = 1000 * 2
    def initialize(p)
      super(p)
      @propagator = p
      @relative_limit_current_measured_device = nil
      @relative_upload_limit_progress_at_measuring_restart = 0
      @current_upload_limit = 0
      @relative_limit_current_measured_job = nil
      @current_download_limit = 0
      QObject.connect(@absolute_limit_timer, QTimer.timeout, this, BandwidthManager.absolute_limit_timer_expired)
      @absolute_limit_timer.set_interval(1000)
      @absolute_limit_timer.start

      QObject.connect(
        @relative_upload_measuring_timer,
        QTimer.timeout,
        this,
        BandwidthManager.relative_upload_measuring_timer_expired
      )

      @relative_upload_measuring_timer.set_interval(RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC)
      @relative_upload_measuring_timer.start
      @relative_upload_measuring_timer.set_single_shot(true)

      QObject.connect(
        @relative_upload_delay_timer,
        QTimer.timeout,
        this,
        BandwidthManager.relative_upload_delay_timer_expired
      )

      @relative_upload_delay_timer.set_single_shot(true)

      QObject.connect(
        @relative_download_measuring_timer,
        QTimer.timeout,
        this,
        BandwidthManager.relative_download_measuring_timer_expired
      )

      @relative_download_measuring_timer.set_interval(RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC)
      @relative_download_measuring_timer.start
      @relative_download_measuring_timer.set_single_shot(true)

      QObject.connect(
        @relative_download_delay_timer,
        QTimer.timeout,
        this,
        BandwidthManager.relative_download_delay_timer_expired
      )

      @relative_download_delay_timer.set_single_shot(true)
    end

    def finalize
    end

    def register_upload_device(p)
      @absolute_upload_device_list.push_back(p)
      @relative_upload_device_list.push_back(p)
      QObject.connect(p, QObject.destroyed, this, BandwidthManager.unregister_upload_device)

      if using_absolute_upload_limit
        p.set_bandwidth_limited(true)
        p.set_choked(false)
      elsif using_relative_upload_limit
        p.set_bandwidth_limited(true)
        p.set_choked(true)
      else
        p.set_bandwidth_limited(false)
        p.set_choked(false)
      end
    end

    def unregister_upload_device(o)
      p = o
      @absolute_upload_device_list.remove(p)
      @relative_upload_device_list.remove(p)

      if p == @relative_limit_current_measured_device
        @relative_limit_current_measured_device = nil
        @relative_upload_limit_progress_at_measuring_restart = 0
      end
    end

    def register_download_job(j)
      @download_job_list.push_back(j)
      connect(j, GETFileJob.about_to_finish_signal, this) { unregister_download_job(j) }

      if using_absolute_download_limit
        j.set_bandwidth_limited(true)
        j.set_choked(false)
      elsif using_relative_download_limit
        j.set_bandwidth_limited(true)
        j.set_choked(true)
      else
        j.set_bandwidth_limited(false)
        j.set_choked(false)
      end
    end

    def unregister_download_job(j)
      j.set_choked(false)
      j.set_bandwidth_limited(false)
      @download_job_list.remove(j)

      if @relative_limit_current_measured_job == j
        @relative_limit_current_measured_job = nil
        @relative_download_limit_progress_at_measuring_restart = 0
      end
    end

    def relative_upload_measuring_timer_expired
      if (
        !using_relative_upload_limit ||
        @relative_upload_device_list.empty
      )
        @relative_upload_delay_timer.set_interval(1000)
        @relative_upload_delay_timer.start

        return
      end

      if @relative_limit_current_measured_device == nil
        Log.debug("sync.bandwidthmanager") { "No device set, just waiting 1 sec" }
        @relative_upload_delay_timer.set_interval(1000)
        @relative_upload_delay_timer.start

        return
      end

      Log.debug("sync.bandwidthmanager") { "#{@relative_upload_device_list.size} Starting Delay" }
      relative_limit_progress_measured = (@relative_limit_current_measured_device.read_with_progress + @relative_limit_current_measured_device.read) / 2
      relative_limit_progress_difference = relative_limit_progress_measured - @relative_upload_limit_progress_at_measuring_restart

      Log.debug("sync.bandwidthmanager") {
        "#{@relative_upload_limit_progress_at_measuring_restart}" \
          "#{relative_limit_progress_measured} #{relative_limit_progress_difference}"
      }

      speedk_b_per_sec = (relative_limit_progress_difference / RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC * 1000.0) / 1024.0

      Log.debug("sync.bandwidthmanager") {
        "#{relative_limit_progress_difference / 1024} kB => #{speedk_b_per_sec} kB/sec on full speed (" \
          "#{@relative_limit_current_measured_device.read_with_progress} #{@relative_limit_current_measured_device.read}" \
          "#{q_abs(@relative_limit_current_measured_device.read_with_progress - @relative_limit_current_measured_device.read)} )"
      }

      upload_limit_percent = -@current_upload_limit
      upload_limit_percent = q_min(upload_limit_percent, 90)
      upload_limit_percent = q_max(10, upload_limit_percent)
      whole_time_msec = (100.0 / upload_limit_percent) * RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC
      wait_time_msec = whole_time_msec - RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC
      real_wait_time_msec = wait_time_msec + whole_time_msec
      Log.debug("sync.bandwidthmanager") { "#{wait_time_msec}  -  #{real_wait_time_msec}  msec for  #{upload_limit_percent} %" }
      @relative_upload_delay_timer.set_interval(real_wait_time_msec)
      @relative_upload_delay_timer.start
      device_count = @relative_upload_device_list.size
      quota_per_device = relative_limit_progress_difference * (upload_limit_percent / 100.0) / device_count + 1.0

      @relative_upload_device_list.each do |ud|
        ud.set_bandwidth_limited(true)
        ud.set_choked(false)
        ud.give_bandwidth_quota(quota_per_device)
        Log.debug("sync.bandwidthmanager") { "Gave #{quota_per_device / 1024.0} kB to #{ud}" }
      end

      @relative_limit_current_measured_device = nil
    end

    def relative_upload_delay_timer_expired
      @relative_upload_measuring_timer.start

      if !using_relative_upload_limit
        return
      end

      if @relative_upload_device_list.empty
        return
      end

      Log.debug("sync.bandwidthmanager") { "#{@relative_upload_device_list.size} Starting measuring" }
      @relative_limit_current_measured_device = @relative_upload_device_list.front
      @relative_upload_device_list.pop_front
      @relative_upload_device_list.push_back(@relative_limit_current_measured_device)
      @relative_upload_limit_progress_at_measuring_restart = (@relative_limit_current_measured_device.read_with_progress + @relative_limit_current_measured_device.read) / 2
      @relative_limit_current_measured_device.set_bandwidth_limited(false)
      @relative_limit_current_measured_device.set_choked(false)

      @relative_upload_device_list.each do |ud|
        if ud != @relative_limit_current_measured_device
          ud.set_bandwidth_limited(true)
          ud.set_choked(true)
        end
      end
    end

    def current_upload_limit
      return @current_upload_limit
    end

    def set_current_upload_limit(new_upload_limit)
      if new_upload_limit != @current_upload_limit
        Log.info("sync.bandwidthmanager") { "Upload Bandwidth limit changed #{@current_upload_limit} #{new_upload_limit}" }
        @current_upload_limit = new_upload_limit

        @relative_upload_device_list.each do |ud|
          if new_upload_limit == 0
            ud.set_bandwidth_limited(false)
            ud.set_choked(false)
          elsif new_upload_limit > 0
            ud.set_bandwidth_limited(true)
            ud.set_choked(false)
          elsif new_upload_limit < 0
            ud.set_bandwidth_limited(true)
            ud.set_choked(true)
          end
        end
      end
    end

    def relative_download_measuring_timer_expired
      if !using_relative_download_limit || @download_job_list.empty
        @relative_download_delay_timer.set_interval(1000)
        @relative_download_delay_timer.start

        return
      end

      if @relative_limit_current_measured_job == nil
        Log.debug("sync.bandwidthmanager") { "No job set, just waiting 1 sec" }
        @relative_download_delay_timer.set_interval(1000)
        @relative_download_delay_timer.start

        return
      end

      Log.debug("sync.bandwidthmanager") { "#{@download_job_list.size} Starting Delay" }
      relative_limit_progress_measured = @relative_limit_current_measured_job.current_download_position
      relative_limit_progress_difference = relative_limit_progress_measured - @relative_download_limit_progress_at_measuring_restart

      Log.debug("sync.bandwidthmanager") {
        "#{@relative_download_limit_progress_at_measuring_restart}" \
          "#{relative_limit_progress_measured} #{relative_limit_progress_difference}"
      }

      speedk_b_per_sec = (relative_limit_progress_difference / RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC * 1000.0) / 1024.0

      Log.debug("sync.bandwidthmanager") {
        "#{relative_limit_progress_difference / 1024} kB => #{speedk_b_per_sec} kB/sec on full speed (" \
          "#{@relative_limit_current_measured_job.current_download_position}"
      }

      download_limit_percent = -@current_download_limit
      download_limit_percent = q_min(download_limit_percent, 90)
      download_limit_percent = q_max(10, download_limit_percent)
      whole_time_msec = (100.0 / download_limit_percent) * RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC
      wait_time_msec = whole_time_msec - RELATIVE_LIMIT_MEASURING_TIMER_INTERVAL_MSEC
      real_wait_time_msec = wait_time_msec + whole_time_msec
      Log.debug("sync.bandwidthmanager") { "#{wait_time_msec}  -  #{real_wait_time_msec}  msec for  #{download_limit_percent} %" }
      @relative_download_delay_timer.set_interval(real_wait_time_msec)
      @relative_download_delay_timer.start
      job_count = @download_job_list.size
      quota = relative_limit_progress_difference * (download_limit_percent / 100.0)

      if quota > 20 * 1024
        Log.info("sync.bandwidthmanager") { "ADJUSTING QUOTA FROM  #{quota}  TO  #{quota - 20.*(1024)}" }
        quota -= 20 * 1024
      end

      quota_per_job = quota / job_count + 1.0

      @download_job_list.each do |gfj|
        gfj.set_bandwidth_limited(true)
        gfj.set_choked(false)
        gfj.give_bandwidth_quota(quota_per_job)
        Log.debug("sync.bandwidthmanager") { "Gave #{quota_per_job / 1024.0} kB to #{gfj}" }
      end

      @relative_limit_current_measured_device = nil
    end

    def relative_download_delay_timer_expired
      @relative_download_measuring_timer.start

      if !using_relative_download_limit
        return
      end

      if @download_job_list.empty
        Log.debug("sync.bandwidthmanager") { "#{@download_job_list.size} No jobs?" }

        return
      end

      Log.debug("sync.bandwidthmanager") { "#{@download_job_list.size} Starting measuring" }
      @relative_limit_current_measured_job = @download_job_list.front
      @download_job_list.pop_front
      @download_job_list.push_back(@relative_limit_current_measured_job)
      @relative_download_limit_progress_at_measuring_restart = @relative_limit_current_measured_job.current_download_position
      @relative_limit_current_measured_job.set_bandwidth_limited(false)
      @relative_limit_current_measured_job.set_choked(false)

      @download_job_list.each do |gfj|
        if gfj != @relative_limit_current_measured_job
          gfj.set_bandwidth_limited(true)
          gfj.set_choked(true)
        end
      end
    end

    def current_download_limit
      return @current_download_limit
    end

    def set_current_download_limit(new_download_limit)
      if new_download_limit != @current_download_limit
        Log.info("sync.bandwidthmanager") { "Download Bandwidth limit changed #{@current_download_limit} #{new_download_limit}" }
        @current_download_limit = new_download_limit

        @download_job_list.each do |j|
          if using_absolute_download_limit
            j.set_bandwidth_limited(true)
            j.set_choked(false)
          elsif using_relative_download_limit
            j.set_bandwidth_limited(true)
            j.set_choked(true)
          else
            j.set_bandwidth_limited(false)
            j.set_choked(false)
          end
        end
      end
    end

    def absolute_limit_timer_expired
      if (
        using_absolute_upload_limit &&
        !@absolute_upload_device_list.empty
      )
        quota_per_device = @current_upload_limit / @absolute_upload_device_list.size
        Log.debug("sync.bandwidthmanager") { "#{quota_per_device} #{@absolute_upload_device_list.size} #{@current_upload_limit}" }

        @absolute_upload_device_list.each do |device|
          device.give_bandwidth_quota(quota_per_device)
          Log.debug("sync.bandwidthmanager") { "Gave  #{quota_per_device / 1024.0}  kB to #{device}" }
        end
      end

      if using_absolute_download_limit && !@download_job_list.empty
        quota_per_job = @current_download_limit / @download_job_list.size
        Log.debug("sync.bandwidthmanager") { "#{quota_per_job} #{@download_job_list.size} #{@current_download_limit}" }

        @download_job_list.each do |j|
          j.give_bandwidth_quota(quota_per_job)
          Log.debug("sync.bandwidthmanager") { "Gave  #{quota_per_job / 1024.0}  kB to #{j}" }
        end
      end
    end
  end
end
