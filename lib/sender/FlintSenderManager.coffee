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

EventEmitter = require 'eventemitter3'
SenderMessageChannel = require './SenderMessageChannel'
SenderMessageBus = require './SenderMessageBus'
Peer = require '../peerjs/peer'
FlintConstants = require '../common/FlintConstants'
Platform = require '../common/Platform'

class FlintSenderManager extends EventEmitter

    constructor: (@options) ->
        if not @options
            throw 'FlintSenderManager constructor error'

        @appId = @options.appId

        @urlBase = @options.urlBase
        @serviceUrl = @urlBase + '/apps/' + @appId
        @host = @options.host

        if @options.useHeartbeat is undefined
            @useHeartbeat = true
        else
            @useHeartbeat = @options.useHeartbeat

        @appState = {}
        @additionalData = {}

        @token = null
        @heartbeatInterval = 3 * 1000
        @heartbeatTimerId = null

        @messageChannel = null
        @messageBusList = {}

    #
    # event: 'customData' + 'available',
    #
    getAdditionalData: ->
        return @additionalData['customData']

    #
    # callback:
    #     (result, state, additionaldata)
    #
    getState: (callback) ->
        headers =
            'Accept': 'application/xml; charset=utf8'
        @_getState @serviceUrl, headers, (result, state) =>
            callback? result, state, @additionalData

    _getState: (url, headers, callback) ->
        @_request 'GET', url, headers, null, (statusCode, responseText) =>
            if statusCode is 200
                @_parseState responseText
                callback? true, @appState.state
            else
                callback? false, 'unknow'

    _parseState: (state) ->
        lines = state.split '\n'
        lines.splice 0, 1
        responseText = lines.join ''
        # todo: different in IE
        parser = new DOMParser()
        doc = parser.parseFromString responseText, 'text/xml'

        @appState.name = doc.getElementsByTagName('name')[0].innerHTML;
        @appState.state = doc.getElementsByTagName('state')[0].innerHTML;

        link = doc.getElementsByTagName 'link'
        if link and link[0]
            @appState.href = link[0].getAttribute 'href'

        additionalData = doc.getElementsByTagName 'additionalData'
        @_parseAdditionalData additionalData

    #
    # "key+'available'" event would be emitted if the new additionaldata contains the certain key
    #
    _parseAdditionalData: (additionalData) ->
        if additionalData?.length > 0
            items = additionalData[0].childNodes
            if items
                _tmpAdditionalData = {}
                for i of items
                    if items[i].tagName and items[i].innerHTML
                        _tmpAdditionalData[items[i].tagName] = items[i].innerHTML
                for key, value of _tmpAdditionalData
                    if @additionalData[key] isnt value
                        @emit key + 'available', value
                @additionalData = _tmpAdditionalData

    #
    # listener:
    # on 'applaunch', (result, token)
    #
    launch: (appInfo, callback) ->
        @_launch 'launch', appInfo, callback

    #
    # listener:
    # on 'apprelaunch', (result, token)
    #
    relaunch: (appInfo, callback) ->
        @_launch 'relaunch', appInfo, callback

    #
    # listener:
    # on 'appjoin', (result, token)
    #
    join: (appInfo, callback) ->
        @_launch 'join', appInfo, callback

    _onLaunchResult: (type, result, token, callback) ->
        callback? type, result, token

        # if success
        if result
            # to get additionaldata before starting heartbeat
            console.log type, ' is ok, getState once'
            setTimeout (=>
                @getState()), 500
        else
            console.log type, ' is failed, stop heartbeat'
            @_stopHeartbeat()

    _launch: (launchType, appInfo, callback) ->
        if (launchType is 'launch') or (launchType is 'relaunch')
            if (not appInfo) or (not appInfo.appUrl)
                throw 'empty appInfo or appUrl'

        if appInfo.useIpc is undefined
            appInfo.useIpc = false
        if (not appInfo.useIpc) and (appInfo.maxInactive is undefined)
            appInfo.maxInactive = -1

        data =
            type: launchType
            app_info:
                url: appInfo.appUrl
                useIpc: appInfo.useIpc
                maxInactive: appInfo.maxInactive

        headers =
            'Content-Type': 'application/json'
        @_request 'POST', @serviceUrl, headers, data, (statusCode, responseText) =>
            if (statusCode is 200) or (statusCode is 201)
                content = JSON.parse responseText
                if content and content.token and content.interval
                    @token = content.token
                    if content.interval <= 3000
                        content.interval = 3000
                    @heartbeatInterval = content.interval
                    if @useHeartbeat
                        @_startHeartbeat()
                    counter = 1
                    _headers =
                        'Accept': 'application/xml; charset=utf8'
                        'Authorization': @token
                    pollingCallback = =>
                        console.log 'wait for launching ', counter, ' times'
                        if counter < 10
                            counter += 1
                            @_getState @serviceUrl, _headers, (result, state) =>
                                if result and (state is 'running') #launch success
                                    @_onLaunchResult 'app' + launchType, true, @token, callback
                                else #wait for 'running'
                                    setTimeout ( =>
                                        pollingCallback()), 1000
                        else #launch timeout
                            @_onLaunchResult 'app' + launchType, false, null, callback
                    pollingCallback()
                else #response error
                    @_onLaunchResult 'app' + launchType, false, null, callback
            else #launch failed
                @_onLaunchResult 'app' + launchType, false, null, callback

    _startHeartbeat: ->
        @_stopHeartbeat()
        @heartbeatTimerId = setInterval (=>
            headers =
                'Accept': 'application/xml; charset=utf8'
                'Authorization': @token
            @_getState @serviceUrl, headers, (result, state) =>
                @emit 'appstate', result, state, @additionalData
        ), @heartbeatInterval

    _stopHeartbeat: ->
        if @heartbeatTimerId
            clearInterval @heartbeatTimerId

    #
    # listener:
    # on 'appstop', result
    #
    stop: (appInfo, callback) ->
        @_stopHeartbeat()
        headers =
            'Accept': 'application/xml; charset=utf8'
        if @token
            headers['Authorization'] = @token
        else
            headers['Authorization'] = 'bad-token'
        @_getState @serviceUrl, headers, (result, state) =>
            if result # @token is available
                if state is 'stopped' # already stopped
                    @_onStop 'appstop', true, callback
                else # send stop request
                    url = @serviceUrl + '/' + @appState.href
                    @_stop 'stop', url, callback
            else # unavailable @token, need join
                console.warn 'stop failed, try join!'
                @join appInfo, (_type, _result, _token)=>
                    @_stopHeartbeat()
                    if _result # join success, continue stopping
                        console.log 'join ok, use token = ', _token, ' to stop!'
                        @token = _token
                        url = @serviceUrl + '/' + @appState.href
                        @_stop 'stop', url, callback
                    else # join failed, stop failed
                        @_onStop 'appstop', false, callback

    disconnect: (callback) ->
        @_stopHeartbeat()
        @_stop 'disconnect', @serviceUrl, callback

    _onStop: (type, result, callback) ->
        callback? type, result

    _stop: (stopType, url, callback) ->
        if not @token
            throw 'empty token, cannot stop'
        headers =
            'Authorization': @token
        @_request 'DELETE', url, headers, null, (statusCode, responseText) =>
            @_clean()
            if statusCode is 200
                @_onStop 'app' + stopType, true, callback
            else
                @_onStop 'app' + stopType, false, callback

    # callback = => (statusCode, responseText)
    _request: (method, url, headers, data, callback) ->
        console.log 'request: method -> ', method, ', url -> ', url, ', headers -> ', headers
        xhr = @_createXhr()
        if not xhr
            throw 'request: failed'

        xhr.open method, url
        if headers
            for key, value of headers
                xhr.setRequestHeader key, value

        xhr.onreadystatechange = =>
            if xhr.readyState is 4
                console.log 'FlintSenderManager received:\n', xhr.responseText
                callback? xhr.status, xhr.responseText

        if data
            xhr.send JSON.stringify(data)
        else
            xhr.send ''

    _createXhr: ->
        platform = Platform.getPlatform().browser
        if platform is 'ffos'
            return new XMLHttpRequest(mozSystem: true)
        else
            return new XMLHttpRequest()

    _createMessageChannel: ->
        if not @messageChannel
            @messageChannel = new SenderMessageChannel FlintConstants.DEFAULT_CHANNEL_NAME
            @messageChannel.on 'open', () =>
                console.log 'sender message channel open!!!'
            @messageChannel.on 'close', () =>
                console.log 'sender message channel close!!!'
            @messageChannel.on 'error', () =>
                console.log 'sender message channel error!!!'
            @_openMessageChannel @messageChannel
        return @messageChannel

    _openMessageChannel: (channel) ->
        @.once channel.getName() + 'available', (channelUrl) =>
            console.log 'available: ', channel.getName() + 'available'
            url = channelUrl + '/senders/' + @token
            console.log channel.getName(), ' open url: ', url
            channel.open url

    createMessageBus: (namespace) ->
        if not namespace
            namespace = FlintConstants.DEFAULT_NAMESPACE
        if not @messageChannel
            @messageChannel = @_createMessageChannel()
        messageBus = @_createMessageBus namespace
        return messageBus

    _createMessageBus: (namespace) ->
        messageBus = null
        if @messageBusList[namespace]
            messageBus = @messageBusList[namespace]
        else
            messageBus = new SenderMessageBus @messageChannel, namespace
            @messageBusList[namespace] = messageBus
        return messageBus

    _createPeer: ->
        peer = new Peer
            host: @host
            port: '9433'
            secure: false
        return peer

    connectReceiverDataPeer: (options) ->
        peer = new Peer
            host: @host
            port: '9433'
            secure: false
        peer.on 'open', (peerId) =>
            console.log 'peer [', peerId, '] opened!!!'
            if @additionalData['dataPeerId']
                peer.connect @additionalData['dataPeerId'], options
            else
                @.once 'dataPeerId' + 'available', (peerId) =>
                    peer.connect peerId, options
        return peer

    callReceiverMediaPeer: (stream, options) ->
        peer = new Peer
            host: @host
            port: '9433'
            secure: false
        peer.on 'open', (peerId) =>
            console.log 'peer [', peerId, '] opened!!!'
            if @additionalData['mediaPeerId']
                peer.call @additionalData['mediaPeerId'], stream, options
            else
                @.once 'mediaPeerId' + 'available', (peerId) =>
                    peer.call peerId, stream, options
        return peer

    _clean: ->
        @messageChannel?.close()
        @messageChannel = null
        @messageBusList = null

module.exports = FlintSenderManager