#!/usr/bin/env ruby
#
# Copyright (C) by Erik Verbruggen <erik@verbruggen.consulting>
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

require_relative "networkinformation"

require "qloggingcategory"

include OCC

class NetworkInformation
  _INSTANCE = nil

  def initialize
  end

  def load_q_network_information_backend
    if !QNetworkInformation.load_default_backend
      Log.warn("gui.netinfo") { "Failed to load default backend of QNetworkInformation." }

      if !QNetworkInformation.load_backend_by_features(:metered)
        Log.warn("gui.netinfo") { "Failed to load backend of QNetworkInformation by metered feature." }

        if !QNetworkInformation.load_backend_by_features(:reachability)
          Log.warn("gui.netinfo") { "Failed to load backend of QNetworkInformation by reachability feature." }
          Log.warn("gui.netinfo") { "Available backends: #{QNetworkInformation.available_backends.join(", ")}" }

          return
        end
      end
    end

    Log.debug("gui.netinfo") { "Loaded network information backend: #{QNetworkInformation.instance.backend_name}" }
    Log.debug("gui.netinfo") { "Supported features: #{QNetworkInformation.instance.supported_features}" }
    Log.debug("gui.netinfo") { "Available backends: #{QNetworkInformation.available_backends.join(", ")}" }
    qni = QNetworkInformation.instance

    if qni
      QObject.connect(qni, QNetworkInformation.reachability_changed, qni) do |reachability|
        Log.info("gui.netinfo") { "Connection Status changed to: #{reachability} captive portal status: #{qni.is_behind_captive_portal}" }
      end
    end
  end

  def instance
    if !_INSTANCE
      @instance = NetworkInformation.new
      load_q_network_information_backend
      qni = QNetworkInformation.instance

      if qni
        connect(qni, QNetworkInformation.is_metered_changed, _INSTANCE, NetworkInformation.is_metered_changed)
        connect(qni, QNetworkInformation.reachability_changed, _INSTANCE, NetworkInformation.reachability_changed)

        connect(
          qni,
          QNetworkInformation.is_behind_captive_portal_changed,
          _INSTANCE,
          NetworkInformation.slot_is_behind_captive_portal_changed
        )
      end
    end

    return _INSTANCE
  end

  def is_metered
    q_net_info = QNetworkInformation.instance

    if q_net_info
      return q_net_info.is_metered
    end

    return false
  end

  def supports(features)
    q_net_info = QNetworkInformation.instance

    if q_net_info
      return q_net_info.supports(features)
    end

    return false
  end

  def is_forced_captive_portal
    return @forced_captive_portal
  end

  def set_forced_captive_portal(onoff)
    if @forced_captive_portal != onoff
      @forced_captive_portal = onoff
      Log.debug("gui.netinfo") { "Switching forced captive portal to #{onoff}" }
      behind_captive_portal = false
      q_net_info = QNetworkInformation.instance

      if q_net_info
        behind_captive_portal = q_net_info.is_behind_captive_portal
      end

      if behind_captive_portal != @forced_captive_portal
        is_behind_captive_portal_changed(@forced_captive_portal)
      end
    end
  end

  def is_behind_captive_portal
    if @forced_captive_portal
      return true
    end

    q_net_info = QNetworkInformation.instance

    if q_net_info
      return q_net_info.is_behind_captive_portal
    end

    return false
  end

  def slot_is_behind_captive_portal_changed(state)
    Log.debug("gui.netinfo") { "OS signals behind captive portal changed to #{state} forced captive portal flag: #{@forced_captive_portal}" }

    if !@forced_captive_portal
      is_behind_captive_portal_changed(state)
    end
  end
end
