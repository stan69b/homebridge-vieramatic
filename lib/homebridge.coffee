### eslint-disable max-classes-per-file ###
### global Service Characteristic Accessory ###

# homebridge vieramatic plugin

# > required **external dependencies**
events = require('events')
net = require('net')
_ = require('lodash')
{ Mutex } = require('async-mutex')

# > required **internal dependencies**
Viera = require('./viera')
Storage = require('./storage')

# helpers
displayName = (str) -> str.toLowerCase().replace(/\s+/gu, '')

sleep = (ms) -> new Promise((resolve) -> setTimeout(resolve, ms))

iterator = (tvs) ->
  for own __, viera of tvs
    if net.isIPv4(viera.ipAddress)
      viera.hdmiInputs = [] unless viera.hdmiInputs?
      yield viera
    else
      # eslint-disable-next-line no-console
      console.error('Ignoring %s as this is NOT a valid IP address!')

validateCryptoNeeds = (tv) ->
  return null unless tv.specs.requiresEncryption
  return new Error(
    "Ignoring TV at #{tv.ipAddress} as it requires encryption but no credentials were
    supplied."
  ) unless tv._appId? and tv._encKey?
  await tv.deriveSessionKeys()
  [err, __] = await tv.requestSessionId()
  return err

class VieramaticAccessory
  constructor: (tv, userConfig, platform) ->
    [@log, @api, @storage] = [platform.log, platform.api, platform.storage]
    [@device, @hdmiInputs] = [tv, userConfig.hdmiInputs]
    [@tvEvent, @mutex] = [new events.EventEmitter(), new Mutex()]

    handler = {
      get: (target, key) ->
        if key is 'isProxy' then return true
        prop = target[key]
        if typeof prop is 'undefined' then return
        # eslint-disable-next-line no-param-reassign
        if not prop.isProxy and typeof prop is 'object' then target[key] = new Proxy(prop, handler)
        target[key]
      set: (target, key, value) =>
        # eslint-disable-next-line no-param-reassign
        target[key] = value
        @storage.save()
        return true
    }
    @device.storage = new Proxy(@storage.get(@device.specs.serialNumber), handler)

  setup: () ->
    { friendlyName, serialNumber, modelName, modelNumber, manufacturer } = @device.specs

    accessory = new Accessory(friendlyName, serialNumber)
    accessory.on('identify', (paired, callback) =>
      @log.debug(friendlyName, 'Identify!!!')
      callback())

    accessoryInformation = accessory.getService(Service.AccessoryInformation)
    accessoryInformation
    .setCharacteristic(Characteristic.Manufacturer, manufacturer)
    .setCharacteristic(Characteristic.Model, "#{modelName} #{modelNumber}")
    .setCharacteristic(Characteristic.SerialNumber, serialNumber)
    .setCharacteristic(Characteristic.Name, friendlyName)

    return accessory

  setupSpeakerService: (friendlyName) ->
    speakerService = new Service.TelevisionSpeaker("#{friendlyName} Volume", 'volumeService')

    speakerService.addCharacteristic(Characteristic.Volume)
    speakerService.addCharacteristic(Characteristic.Active)
    speakerService.setCharacteristic(
      Characteristic.VolumeControlType,
      Characteristic.VolumeControlType.ABSOLUTE
    )

    speakerService
    .getCharacteristic(Characteristic.Mute)
    .on('get', @getMute)
    .on('set', @setMute)
    speakerService
    .getCharacteristic(Characteristic.Volume)
    .on('get', @getVolume)
    .on('set', @setVolume)
    speakerService.getCharacteristic(Characteristic.VolumeSelector).on('set', @setVolumeSelector)

    return speakerService

  add: () ->
    { friendlyName } = @device.specs

    unless @device.storage.data?
      @log.debug("Initializing '#{friendlyName}' for the first time.")
      # eslint-disable-next-line coffee/no-constant-condition
      loop
        [err, @applications] = await @device.getApps()
        break unless err

        @log.warn(
          'Unable to fetch Application list from TV (as it seems to be in standby).
          Trying again in 5s.'
        )
        sleep(5000)

      @device.storage.data = {
        inputs: {
          hdmi: @hdmiInputs,
          applications: { ...@applications }
        }
        specs: { ...@device.specs }
      }
    else
      @log.debug("Restoring '#{friendlyName}'.")
      { inputs } = @device.storage.data
      [err, @applications] = await @device.getApps()
      if err
        @log.debug("#{err.message}, getting previously cached ones instead")
        @applications = inputs.applications

      for own i, input of @hdmiInputs
        idx = _.findIndex(inputs.hdmi, ['id', input.id.toString()])
        unless idx < 0
          # eslint-disable-next-line no-param-reassign
          @hdmiInputs[i].hiden = inputs.hdmi[idx].hiden if inputs.hdmi[idx].hiden?

    @accessory = await @setup()

    tvService = new Service.Television(friendlyName, 'Television')
    tvService
    .setCharacteristic(Characteristic.ConfiguredName, friendlyName)
    .setCharacteristic(Characteristic.SleepDiscoveryMode, 1)
    tvService.addCharacteristic(Characteristic.RemoteKey)
    tvService.addCharacteristic(Characteristic.PowerModeSelection)
    @accessory.addService(tvService)

    speakerService = @setupSpeakerService(friendlyName)
    tvService.addLinkedService(speakerService)
    @accessory.addService(speakerService)

    customSpeakerService = new Service.Fan("#{friendlyName} Volume", 'VolumeAsFanService')
    tvService.addLinkedService(customSpeakerService)
    @accessory.addService(customSpeakerService)

    tvService
    .getCharacteristic(Characteristic.Active)
    .on('get', @getPowerStatus)
    .on('set', @setPowerStatus)

    tvService.getCharacteristic(Characteristic.RemoteKey).on('set', @remoteControl)
    tvService.getCharacteristic(Characteristic.ActiveIdentifier).on('set', @setInput)
    tvService
    .getCharacteristic(Characteristic.PowerModeSelection)
    .on('set', (value, callback) =>
      [e, __] = await @device.sendCommand('MENU')
      if e
        @log.error('(PowerModeSelection.set)', e)
        callback(null, null)
      else
        callback(null, value))

    customSpeakerService
    .getCharacteristic(Characteristic.On)
    .on('get', (callback) =>
      { value } = tvService.getCharacteristic(Characteristic.Active)
      @log.debug('(customSpeakerService/On.get)', value)
      callback(null, value))
    .on('set', (value, callback) =>
      @log.debug('(customSpeakerService/On.set)', value)
      if tvService.getCharacteristic(Characteristic.Active).value is 0
        callback(null, false)
      else
        callback(null, not value))

    customSpeakerService
    .getCharacteristic(Characteristic.RotationSpeed)
    .on('get', @getVolume)
    .on('set', @setVolume)

    # TV Tuner
    await @configureInputSource('TUNER', 'TV Tuner', 500)

    # HDMI inputs
    for own __, input of @hdmiInputs
      if _.find(@accessory.services, { displayName: displayName(input.name) })
        @log.error('ignored duplicated entry in HDMI inputs list...')
      else
        await @configureInputSource('HDMI', input.name, parseInt(input.id, 10))

    # Apps
    for own id, app of @applications
      await @configureInputSource('APPLICATION', app.name, 1000 + parseInt(id, 10))

    @tvEvent
    .on('INTO_STANDBY', () => @updateTVstatus(false))
    .on('POWERED_ON', () => @updateTVstatus(true))

    initialStatus = await @device.isTurnedOn()
    if initialStatus then @tvEvent.emit('POWERED_ON') else @tvEvent.emit('INTO_STANDBY')

    setInterval(@getPowerStatus, 5000)

    @accessory.reachable = true

    @api.publishExternalAccessories('homebridge-vieramatic', [@accessory])

  configureInputSource: (type, configuredName, identifier) =>
    visibility = () =>
      hiden = 0
      { inputs } = @device.storage.data
      # eslint-disable-next-line default-case
      switch type
        when 'HDMI'
          idx = _.findIndex(inputs.hdmi, ['id', identifier.toString()])
          if inputs.hdmi[idx].hiden?
            { hiden } = inputs.hdmi[idx]
          else
            inputs.hdmi[idx].hiden = hiden
        when 'APPLICATION'
          real = identifier - 1000
          if inputs.applications[real].hiden?
            { hiden } = inputs.applications[real]
          else
            inputs.applications[real].hiden = 1
            hiden = 1
        when 'TUNER'
          if inputs.TUNER? then { hiden } = inputs.TUNER else inputs.TUNER = { hiden }

      return hiden

    source = new Service.InputSource(displayName(configuredName), identifier)
    @accessory.getService(Service.Television).addLinkedService(source)
    @accessory.addService(source)

    hiden = await visibility()
    source
    .setCharacteristic(Characteristic.InputSourceType, Characteristic.InputSourceType[type])
    .setCharacteristic(Characteristic.CurrentVisibilityState, hiden)
    .setCharacteristic(Characteristic.TargetVisibilityState, hiden)
    .setCharacteristic(Characteristic.Identifier, identifier)
    .setCharacteristic(Characteristic.ConfiguredName, configuredName)
    .setCharacteristic(Characteristic.IsConfigured, Characteristic.IsConfigured.CONFIGURED)

    source
    .getCharacteristic(Characteristic.TargetVisibilityState)
    .on('set', (state, callback) =>
      id = source.getCharacteristic(Characteristic.Identifier).value
      { inputs } = @device.storage.data
      # eslint-disable-next-line default-case
      switch
        when id < 100
          # hdmi input
          idx = _.findIndex(inputs.hdmi, ['id', id.toString()])
          inputs.hdmi[idx].hiden = state
        when id > 999
          real = id - 1000
          inputs.applications[real].hiden = state
        when id is 500
          inputs.TUNER = { hiden: state }

      source.getCharacteristic(Characteristic.CurrentVisibilityState).updateValue(state)
      callback())

  getMute: (callback) =>
    status = await @device.isTurnedOn()
    return [null, true] unless status

    [err, mute] = await @device.getMute()
    if err
      @log.error('(getMute) %s', err)
      callback(null, true)
    else
      @log.debug('(getMute)', mute)
      callback(null, mute)

  setMute: (mute, callback) =>
    @log.debug('(setMute)', mute)
    [err, __] = await @device.setMute(mute)
    if err
      @log.error('(setMute)/(%s) %s', mute, err)
      callback(null, mute)
    else
      callback(null, not mute)

  setVolume: (value, callback) =>
    @log.debug('(setVolume)', value)
    [err, __] = await @device.setVolume(value)
    if err
      @log.error('(setVolume)/(%s) %s', value, err)
      callback(null, null)
    else
      callback(null, value)

  getVolume: (callback) =>
    [err, volume] = await @device.getVolume()
    if err
      @log.error('(getVolume) %s', err)
      callback(null, null)
    else
      @log.debug('(getVolume)', volume)
      callback(null, volume)

  setVolumeSelector: (key, callback) =>
    @log.debug('setVolumeSelector', key)
    # eslint-disable-next-line default-case
    switch key
      when Characteristic.VolumeSelector.INCREMENT
        # Volume up
        cmd = 'VOLUP'
      when Characteristic.VolumeSelector.DECREMENT
        # Volume down
        cmd = 'VOLDOWN'

    [err, __] = await @device.sendCommand(cmd)
    if err then @log.error('(setVolumeSelector) unable to change volume', err)
    callback(null)

  updateTVstatus: (powered) =>
    [active, mute, On] = [Characteristic.Active, Characteristic.Mute, Characteristic.On]

    tvService = @accessory.getService(Service.Television)
    speakerService = @accessory.getService(Service.TelevisionSpeaker)
    customSpeakerService = @accessory.getService(Service.Fan)

    speakerService.getCharacteristic(active).updateValue(powered)
    tvService.getCharacteristic(active).updateValue(powered)
    unless powered
      speakerService.getCharacteristic(mute).updateValue(true)
      customSpeakerService.getCharacteristic(On).updateValue(false)
    else
      [__, muteStatus] = await @device.getMute()
      speakerService.getCharacteristic(mute).updateValue(muteStatus)
      customSpeakerService.getCharacteristic(On).updateValue(not muteStatus)

  getPowerStatus: (callback) =>
    await return @mutex.runExclusive(() =>
      status = await @device.isTurnedOn()
      if status then @tvEvent.emit('POWERED_ON') else @tvEvent.emit('INTO_STANDBY')
      if callback? then callback(null, status) else status
    )

  setPowerStatus: (turnOn, callback) =>
    await return @mutex.runExclusive(() =>
      if turnOn is 1 then str = 'ON' else str = 'into STANDBY'
      poweredOn = await @device.isTurnedOn()
      @log.debug('(setPowerStatus)', turnOn, poweredOn)

      switch
        when turnOn is 1 and poweredOn is true, turnOn is 0 and poweredOn is false
          @log.debug('TV is already %s: Ignoring!', str)
        else
          [err, __] = await @device.sendCommand('POWER')
          if err
            @log.error("(setPowerStatus)/#{turnOn} - unable to power cycle TV - probably unpowered")
          else
            if turnOn is 1 then @tvEvent.emit('POWERED_ON') else @tvEvent.emit('INTO_STANDBY')
            @log.debug('Turned TV %s', str)
      callback()
    )

  remoteControl: (keyId, callback) =>
    # https://github.com/KhaosT/HAP-NodeJS/blob/master/src/lib/gen/HomeKit-TV.ts#L235
    # eslint-disable-next-line default-case
    switch keyId
      when 0 # Rewind
        cmd = 'REW'
      when 1 # Fast Forward
        cmd = 'FF'
      when 2 # Next Track
        cmd = 'SKIP_NEXT'
      when 3 # Previous Track
        cmd = 'SKIP_PREV'
      when 4 # Up Arrow
        cmd = 'UP'
      when 5 # Down Arrow
        cmd = 'DOWN'
      when 6 # Left Arrow
        cmd = 'LEFT'
      when 7 # Right Arrow
        cmd = 'RIGHT'
      when 8 # Select
        cmd = 'ENTER'
      when 9 # Back
        cmd = 'RETURN'
      when 10 # Exit
        cmd = 'CANCEL'
      when 11 # Play / Pause
        cmd = 'PLAY'
      when 15 # Information
        cmd = 'HOME'

    @log.debug(cmd)
    [err, __] = await @device.sendCommand(cmd)
    if err
      @log.error('(remoteControl)/(%s) %s', cmd, err)
      callback(null, null)
    else
      callback(null, keyId)

  setInput: (value, callback) =>
    fn = () =>
      switch
        when value < 100
          @log.debug('(setInput) switching to HDMI INPUT ', value)
          @device.sendHDMICommand(value)
        when value > 999
          real = value - 1000
          app = @applications[real]
          @log.debug('(setInput) switching to App', app.name)
          @device.sendAppCommand(app.id)
        when value is 500
          @log.debug('(setInput) switching to internal TV tunner')
          @device.sendCommand('AD_CHANGE')
        else
          err = new Error("Supported values are < 100, > 999 or 500, #{value} is neither")
          @log.error(err)
          [err, null]

    [err, __] = await fn()
    if err
      @log.error('(setInput)/(%s) %s', value, err)
      callback(null, null)
    else
      callback(null, value)

class VieramaticPlatform
  constructor: (log, config, api) ->
    log.info('Vieramatic Init')

    [@log, @api, @previousAccessories] = [log, api, []]

    @config = {
      tvs: config?.tvs or []
    }
    @storage = new Storage(api)
    @storage.init()

    @api.on('didFinishLaunching', @init) if @api

  init: () =>
    for own cached of @previousAccessories
      @api.unregisterPlatformAccessories('homebridge-vieramatic', 'PanasonicVieraTV', [cached])

    for viera from iterator(@config.tvs)
      tv = new Viera(viera.ipAddress, @log, viera.appId, viera.encKey)

      unless await tv.isReachable()
        @log.error(
          "Ignoring TV (at '#{tv.ipAddress}') as it is unreachable. Likely to be powered off."
        )
        continue

      # eslint-disable-next-line coffee/no-constant-condition
      loop
        [err, tv.specs] = await tv.getSpecs()
        break unless err
        @log.warn(
          "An unexpected error happened while fetching TV metadata. Please do make sure that the
          TV is powered on and NOT in stand-by.\n\n\n#{err}\n\n\nTrying again in 10s."
        )
        sleep(10000)

      @log.debug(tv)

      err = await validateCryptoNeeds(tv)
      unless err
        try
          await new VieramaticAccessory(tv, viera, @).add()
        catch Err
          err = new Error(
            "An unexpected error happened while adding Viera TV (at '#{tv.ipAddress}')
            as an homebridge Accessory.\n\n\n#{Err}"
          )
      @log.error(err) if err

    @log.info('DidFinishLaunching')

  configureAccessory: (tv) =>
    @previousAccessories.push(tv)

#
# ## Public API
# --------
module.exports = { VieramaticPlatform, Viera }
