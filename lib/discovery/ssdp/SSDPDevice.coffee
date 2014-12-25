#
# Copyright (C) 2013-2014, The OpenFlint Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

FlintDevice = require '../../sender/FlintDevice'

class SSDPDevice extends FlintDevice

    constructor: (deviceDesc) ->
        super
        # set values

        @urlBase = deviceDesc.urlBase

        if @urlBase.slice(-5) isnt ':9431'
            @urlBase += ':9431'

        @friendlyName = deviceDesc.friendlyName
        # make the udn as the uniqueId of SSDP device
        @uniqueId = deviceDesc.udn

    getDeviceType: ->
        return 'ssdp'

module.exports = SSDPDevice
