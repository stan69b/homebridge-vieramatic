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
sleep = (ms) -> new Promise((resolve) -> setTimeout(resolve, ms))

class Vieramatic
  [tvEvent, mutex] = [new events.EventEmitter(), new Mutex()]

  constructor: (log, config, api) ->
    log.info('Vieramatic Init')

    [@log, @api, @previousAccessories] = [log, api, []]

    @config = {
      tvs: config?.tvs or []
    }
    @storage = new Storage(api)

    for own cached of @previousAccessories
      @api.unregisterPlatformAccessories('homebridge-vieramatic', 'PanasonicVieraTV', [cached])

    @api.on('didFinishLaunching', @init) if @api

  init: () =>
    await @storage.init()
    iterator = (tvs) ->
      for own __, viera of tvs
        if net.isIPv4(viera.ipAddress)
          viera.hdmiInputs = [] unless viera.hdmiInputs?
          yield viera
        else
          # eslint-disable-next-line no-console
          console.error('Ignoring %s as this is NOT a valid IP address!')

    for viera from iterator(@config.tvs)
      viera.hdmiInputs = [] unless viera.hdmiInputs?
      tv = new Viera(viera.ipAddress, @log, viera.appId, viera.encKey)

      unless await tv.isReachable()
        @log.error("Viera TV (at '#{tv.ipAddress}') was unreachable. Likely to be powered off.")
        continue

      brk = false
      until tv.specs?.serialNumber? or brk
        [err, specs] = await tv.getSpecs()
        if err
          @log.warn(
            "An unexpected error happened while fetching TV metadata. Please do make sure that the
            TV is powered on and NOT in stand-by.\n\n\n#{err}\n\n\nTrying again in 10s."
          )
          sleep(10000)
          continue

        tv.specs = specs
        @log.debug(tv)

        if tv.specs.requiresEncryption
          unless tv._appId? and tv._encKey?
            @log.error(
              "Ignoring TV at #{viera.ipAddress} as it requires encryption but no credentials were
              supplied."
            )
            brk = true
            continue

          await tv.deriveSessionKeys()
          [err, __] = await tv.requestSessionId()
          if err
            @log.error(
              "An unexpected error happened while requesting a sessionID for '#{tv.ipAddress}'
              \n\n#{err}"
            )
            brk = true
            continue

        try
          await @addAccessory(tv, viera.hdmiInputs)
        catch Err
          @log.error(
            "An unexpected error happened while adding Viera TV (at '#{tv.ipAddress}')
            as an homebridge Accessory.\n\n\n#{Err}"
          )
          brk = true

    @log.info('DidFinishLaunching')

  setupNewAccessory: () ->
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

    return speakerService

  newAccessoryPreflight: (hdmiInputs) ->
    { serialNumber } = @device.specs
    @device.storage = new Proxy(@storage.get(serialNumber), {
      set: (obj, prop, value) =>
        # eslint-disable-next-line no-param-reassign
        obj[prop] = value
        @storage.save()
        return true
    })

    unless @device.storage.data?
      @log.debug("Initializing '#{@device.specs.friendlyName}' for the first time.")
      while @applications.length is 0
        [err, apps] = await @device.getApps()
        if err
          @log.warn(
            'Unable to fetch Application list from TV (as it seems to be in standby).
             Trying again in 5s.'
          )
          sleep(5000)
        else
          @applications = _.cloneDeep(apps)

      @device.storage.data = {
        inputs: {
          hdmi: hdmiInputs,
          applications: { ...@applications }
        }
        specs: { ...@device.specs }
      }
    else
      @log.debug("Restoring '#{@device.specs.friendlyName}'.")
      [err, apps] = await @device.getApps()
      if err
        @log.debug("#{err.message}, getting previously cached ones instead")
        @applications = _.cloneDeep(@device.storage.data.inputs.applications)
      else
        @applications = _.cloneDeep(apps)

      for own i, input of hdmiInputs
        idx = _.findIndex(@device.storage.data.inputs.hdmi, ['id', input.id.toString()])
        unless idx < 0
          if @device.storage.data.inputs.hdmi[idx].hiden?
            # eslint-disable-next-line no-param-reassign
            hdmiInputs[i].hiden = @device.storage.data.inputs.hdmi[idx].hiden
      # force flush
      @device.storage.data.inputs.hdmi = _.cloneDeep(hdmiInputs)
      @device.storage.data.inputs.applications = { ...@applications }
      @device.storage.data = _.cloneDeep(@device.storage.data)

  addAccessory: (tv, hdmiInputs) =>
    [@device, @applications] = [_.cloneDeep(tv), []]
    { friendlyName } = @device.specs

    await @newAccessoryPreflight(hdmiInputs)

    newAccessory = await @setupNewAccessory()

    tvService = new Service.Television(friendlyName, 'Television')
    tvService
    .setCharacteristic(Characteristic.ConfiguredName, friendlyName)
    .setCharacteristic(Characteristic.SleepDiscoveryMode, 1)
    tvService.addCharacteristic(Characteristic.RemoteKey)
    tvService.addCharacteristic(Characteristic.PowerModeSelection)
    newAccessory.addService(tvService)

    speakerService = @setupSpeakerService(friendlyName)
    tvService.addLinkedService(speakerService)
    newAccessory.addService(speakerService)

    customSpeakerService = new Service.Fan("#{friendlyName} Volume", 'VolumeAsFanService')
    tvService.addLinkedService(customSpeakerService)
    newAccessory.addService(customSpeakerService)

    tvService
    .getCharacteristic(Characteristic.Active)
    .on('get', @getPowerStatus)
    .on('set', @setPowerStatus)

    tvService.getCharacteristic(Characteristic.RemoteKey).on('set', @remoteControl)
    tvService.getCharacteristic(Characteristic.ActiveIdentifier).on('set', @setInput)
    tvService
    .getCharacteristic(Characteristic.PowerModeSelection)
    .on('set', (value, callback) =>
      [err, __] = await @device.sendCommand('MENU')
      if err then callback(err, null) else callback(null, value))

    customSpeakerService
    .getCharacteristic(Characteristic.On)
    # .on('get', @getMute)
    # .on('set', @setMute)
    .on('get', (callback) =>
      { value } = tvService.getCharacteristic(Characteristic.Active)
      @log.debug('(customSpeakerService/On.get)', value)
      if value is 0 then callback(null, false) else callback(null, true))
    .on('set', (value, callback) =>
      @log.debug('(customSpeakerService/On.set)', value)
      if tvService.getCharacteristic(Characteristic.Active).value is 0
        customSpeakerService.getCharacteristic(Characteristic.On).updateValue(false)
        callback(null, value)
      else
        callback(null, not value))

    customSpeakerService
    .getCharacteristic(Characteristic.RotationSpeed)
    .on('get', @getVolume)
    .on('set', @setVolume)

    # TV Tuner
    configuredName = 'TV Tuner'
    displayName = configuredName.toLowerCase().replace(' ', '')

    svc = new Service.InputSource(displayName, 500)
    tvService.addLinkedService(svc)
    newAccessory.addService(svc)
    await @configureInputSource(svc, 'TUNER', configuredName, parseInt(500, 10))

    # HDMI inputs
    for own __, input of hdmiInputs
      configuredName = input.name
      displayName = configuredName.toLowerCase().replace(' ', '')

      if _.find(newAccessory.services, { displayName })
        @log.error('ignored duplicated entry in HDMI inputs list...')
      else
        svc = new Service.InputSource(displayName, input.id)
        tvService.addLinkedService(svc)
        newAccessory.addService(svc)
        await @configureInputSource(svc, 'HDMI', configuredName, parseInt(input.id, 10))

    # Apps
    for own id, app of @applications
      configuredName = app.name
      displayName = configuredName.toLowerCase().replace(' ', '')
      svc = new Service.InputSource(displayName, app.id)
      tvService.addLinkedService(svc)
      newAccessory.addService(svc)
      await @configureInputSource(svc, 'APPLICATION', configuredName, 1000 + parseInt(id, 10))

    tvEvent
    .on('INTO_STANDBY', () => @updateTVstatus(false, tvService, customSpeakerService))
    .on('POWERED_ON', () => @updateTVstatus(true, tvService, customSpeakerService))

    setInterval(@getPowerStatus, 5000)

    newAccessory.reachable = true

    @api.publishExternalAccessories('homebridge-vieramatic', [newAccessory])

  configureAccessory: (tv) =>
    @previousAccessories.push(tv)

  configureInputSource: (source, type, configuredName, identifier) =>
    hiden = false
    # eslint-disable-next-line default-case
    switch type
      when 'HDMI'
        idx = _.findIndex(@device.storage.data.inputs.hdmi, ['id', identifier.toString()])
        if @device.storage.data.inputs.hdmi[idx].hiden?
          { hiden } = @device.storage.data.inputs.hdmi[idx]
      when 'APPLICATION'
        real = identifier - 1000
        if @device.storage.data.inputs.applications[real].hiden?
          { hiden } = @device.storage.data.inputs.applications[real]
        else
          hiden = true
      when 'TUNER'
        if @device.storage.data.inputs.TUNER?
          { hiden } = @device.storage.data.inputs.TUNER

    @device.storage.data = _.cloneDeep(@device.storage.data)
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

      # eslint-disable-next-line default-case
      switch
        when id < 100
          # hdmi input
          _idx = _.findIndex(@device.storage.data.inputs.hdmi, ['id', id.toString()])
          @device.storage.data.inputs.hdmi[_idx].hiden = state
        when id > 999
          _real = id - 1000
          @device.storage.data.inputs.applications[_real].hiden = state
        when id is 500
          @device.storage.data.inputs.TUNER = { hiden: state }

      @device.storage.data = _.cloneDeep(@device.storage.data)
      source.getCharacteristic(Characteristic.CurrentVisibilityState).updateValue(state)
      callback())

  getMute: (callback) =>
    [err, mute] = await @device.getMute()
    if err
      callback(err, null)
    else
      @log.debug('(getMute)', mute)
      callback(null, mute)

  setMute: (mute, callback) =>
    @log.debug('(setMute)', mute)
    [err, __] = await @device.setMute(mute)
    if err then callback(err, null) else callback(null, not mute)

  setVolume: (value, callback) =>
    @log.debug('(setVolume)', value)
    [err, __] = await @device.setVolume(value)
    if err then callback(err, null) else callback(null, value)

  getVolume: (callback) =>
    [err, volume] = await @device.getVolume()
    if err
      callback(err, null)
    else
      @log.debug('(getVolume)', volume)
      callback(null, volume)

  # eslint-disable-next-line coffee/class-methods-use-this
  updateTVstatus: (powered, tvService, customSpeakerService) ->
    active = Characteristic.Active
    [speakerStatus, tvStatus] = if powered then [true, active.ACTIVE] else [false, active.INACTIVE]

    customSpeakerService.getCharacteristic(Characteristic.On).updateValue(speakerStatus)
    tvService.getCharacteristic(active).updateValue(tvStatus)

  getPowerStatus: (callback) =>
    mutex.runExclusive(() =>
      status = await @device.isTurnedOn()
      if status then tvEvent.emit('POWERED_ON') else tvEvent.emit('INTO_STANDBY')
      if callback? then callback(null, status) else status
    )

  setPowerStatus: (turnOn, callback) =>
    poweredOn = await @device.isTurnedOn()
    @log.debug('(setPowerStatus)', turnOn, poweredOn)
    if turnOn is 1 then str = 'ON' else str = 'into STANDBY'
    if (turnOn is 1 and poweredOn) or (turnOn is 0 and not poweredOn)
      @log.debug('TV is already %s: Ignoring!', str)
    else
      [err, __] = await @device.sendCommand('POWER')
      if err
        return callback(new Error('unable to power cycle TV - probably without power'))
      if turnOn is 1 then tvEvent.emit('POWERED_ON') else tvEvent.emit('INTO_STANDBY')
      @log.debug('Turned TV %s', str)
    # FIXME revise callback handling here
    callback()

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
    if err then callback(err, null) else callback(null, keyId)

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
    if err then callback(err, null) else callback(null, value)

#
# ## Public API
# --------
module.exports = Vieramatic
