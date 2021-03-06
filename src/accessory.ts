import {
  Characteristic,
  CharacteristicGetCallback,
  CharacteristicSetCallback,
  CharacteristicValue,
  Logger,
  PlatformAccessory,
  Service
} from 'homebridge'

import wakeOnLan from '@mi-sec/wol'

import { Abnormal, Outcome } from './helpers'
import VieramaticPlatform from './platform'
import { VieraApps, VieraTV } from './viera'

// helpers ...
const displayName = (string: string): string => {
  return string.toLowerCase().replace(/\s+/gu, '')
}

interface HdmiInput {
  name: string
  id: string
  hidden?: 0 | 1
}

interface UserConfig {
  friendlyName?: string
  ipAddress: string
  mac?: string
  encKey?: string
  appId?: string
  customVolumeSlider?: boolean
  disabledAppSupport?: boolean
  hdmiInputs: HdmiInput[]
}

type InputType = 'HDMI' | 'APPLICATION' | 'TUNER'

async function sleep(ms: number): Promise<unknown> {
  return await new Promise((resolve) => setTimeout(resolve, ms))
}

class VieramaticPlatformAccessory {
  private readonly service: Service

  private readonly Service: typeof Service

  private readonly Characteristic: typeof Characteristic

  private readonly log: Logger

  private readonly storage

  private readonly device: VieraTV

  constructor(
    private readonly platform: VieramaticPlatform,
    private readonly accessory: PlatformAccessory,
    private readonly userConfig: UserConfig,
    private readonly tvApps: VieraApps
  ) {
    this.log = this.platform.log
    this.Service = this.platform.Service
    this.Characteristic = this.platform.Characteristic

    this.log.debug(JSON.stringify(this.userConfig, undefined, 2))

    const handler = {
      get: (obj, prop): unknown => {
        if (prop === 'isProxy') {
          return true
        }
        const property = obj[prop]
        if (typeof property === 'undefined') {
          return
        }
        if (property.isProxy == null && typeof property === 'object') {
          obj[prop] = new Proxy(property, handler)
        }
        return obj[prop]
      },
      set: (obj, prop, value): boolean => {
        obj[prop] = value
        this.platform.storage.save()
        return true
      }
    }

    this.device = this.accessory.context.device
    this.storage = new Proxy(
      this.platform.storage.get(this.device.specs.serialNumber),
      handler
    )

    const svc = this.accessory.getService(this.Service.AccessoryInformation)
    if (svc != null) {
      svc
        .setCharacteristic(
          this.Characteristic.Manufacturer,
          this.device.specs.manufacturer
        )
        .setCharacteristic(
          this.Characteristic.Model,
          `${this.device.specs.modelName} ${this.device.specs.modelNumber}`
        )
        .setCharacteristic(
          this.Characteristic.SerialNumber,
          this.device.specs.serialNumber
        )
    }

    this.accessory.on('identify', () => {
      this.log.info(this.device.specs.friendlyName, 'Identify!!!')
    })

    this.service = this.accessory.addService(this.Service.Television)

    this.service.setCharacteristic(
      this.Characteristic.Name,
      this.device.specs.friendlyName
    )

    this.service
      .setCharacteristic(
        this.Characteristic.ConfiguredName,
        this.device.specs.friendlyName
      )
      .setCharacteristic(
        this.Characteristic.SleepDiscoveryMode,
        this.Characteristic.SleepDiscoveryMode.ALWAYS_DISCOVERABLE
      )

    this.service
      .addCharacteristic(this.Characteristic.PowerModeSelection)
      .on(
        'set',
        async (
          value: CharacteristicValue,
          callback: CharacteristicSetCallback
        ) => {
          const outcome = await this.device.sendCommand('MENU')
          if (Abnormal(outcome)) {
            this.log.error(
              'unexpected error in PowerModeSelection.set',
              outcome.error
            )
          }
          callback(undefined, value)
        }
      )

    this.service
      .getCharacteristic(this.Characteristic.Active)
      .on('set', this.setPowerStatus.bind(this))
      .on('get', this.getPowerStatus.bind(this))
    this.service
      .getCharacteristic(this.Characteristic.RemoteKey)
      .on('set', this.remoteControl.bind(this))
    this.service
      .getCharacteristic(this.Characteristic.ActiveIdentifier)
      .on('set', this.setInput.bind(this))

    const speakerService = this.accessory.addService(
      this.Service.TelevisionSpeaker,
      `${this.device.specs.friendlyName} Volume`,
      'volumeService'
    )

    speakerService.addCharacteristic(this.Characteristic.Volume)
    speakerService.addCharacteristic(this.Characteristic.Active)
    speakerService.setCharacteristic(
      this.Characteristic.VolumeControlType,
      this.Characteristic.VolumeControlType.ABSOLUTE
    )
    this.service.addLinkedService(speakerService)

    speakerService
      .getCharacteristic(this.Characteristic.Mute)
      .on('get', this.getMute.bind(this))
      .on('set', this.setMute.bind(this))
    speakerService
      .getCharacteristic(this.Characteristic.Volume)
      .on('get', this.getVolume.bind(this))
      .on('set', this.setVolume.bind(this))
    speakerService
      .getCharacteristic(this.Characteristic.VolumeSelector)
      .on('set', this.setVolumeSelector.bind(this))

    if (this.userConfig.customVolumeSlider === true) {
      const customSpeakerService = this.accessory.addService(
        this.Service.Fan,
        `${this.device.specs.friendlyName} Volume`,
        'VolumeAsFanService'
      )
      this.service.addLinkedService(customSpeakerService)

      customSpeakerService
        .getCharacteristic(this.Characteristic.On)
        .on('get', (callback: CharacteristicGetCallback) => {
          const { value } = this.service.getCharacteristic(
            this.Characteristic.Active
          )
          this.log.debug('(customSpeakerService/On.get)', value)
          return callback(undefined, value)
        })
        .on(
          'set',
          async (
            value: CharacteristicValue,
            callback: CharacteristicSetCallback
          ) => {
            this.log.debug('(customSpeakerService/On.set)', value)
            switch (
              this.service.getCharacteristic(this.Characteristic.Active).value
            ) {
              case this.Characteristic.Active.INACTIVE:
                await this.device.setMute(false)
                return callback(undefined, false)
              case this.Characteristic.Active.ACTIVE:
              default:
                await this.device.setMute(!(value as boolean))
                return callback(undefined, !(value as boolean))
            }
          }
        )

      customSpeakerService
        .getCharacteristic(this.Characteristic.RotationSpeed)
        .on('get', this.getVolume.bind(this))
        .on('set', this.setVolume.bind(this))
    }

    setInterval(async () => {
      await this.getPowerStatus()
    }, 5000)

    this.userConfig.hdmiInputs ||= []

    // ignore HDMI configs
    this.userConfig.hdmiInputs = this.userConfig.hdmiInputs.filter((input) => {
      const required = ['id', 'name']

      for (const req of required)
        if (!Object.prototype.hasOwnProperty.call(input, req)) {
          this.log.warn(
            'ignoring hdmi input "%s" as it has a missing required field ("%s" is required)',
            input,
            req
          )
          return false
        }

      return true
    })

    if (this.storage.data == null) {
      this.storage.data = {
        inputs: {
          applications: { ...this.tvApps },
          hdmi: this.userConfig.hdmiInputs
        },
        ipAddress: this.userConfig.ipAddress,
        specs: { ...this.device.specs }
      }
      // add default TUNER (live TV)... visible by default
      this.storage.data.inputs.TUNER = { hidden: 0 }
      // by default all hdmiInputs will be visible
      this.storage.data.inputs.hdmi.forEach((element) => {
        element.hidden = 0
      })
      // by default all apps will be hidden
      Object.entries(this.storage.data.inputs.applications).forEach(
        (_element, index) => {
          this.storage.data.inputs.applications[index].hidden = 1
        }
      )
    } else {
      this.log.debug('Restoring', this.device.specs.friendlyName)
      // check for new user added inputs
      userConfig.hdmiInputs.forEach((input) => {
        const fn = function isThere(element): boolean {
          return element.id === input.id && element.name === input.name
        }
        const found = this.storage.data.inputs.hdmi.findIndex((x) => fn(x))
        if (found === -1) {
          this.log.info(
            "adding HDMI input '%s' - '%s' as it was appended to config.json",
            input.id,
            input.name
          )

          input.hidden = 0
          this.storage.data.inputs.hdmi.push(input)
        }
      })
      // check for user removed inputs
      const shallow: unknown[] = []
      this.storage.data.inputs.hdmi.forEach((input) => {
        const fn = function isThere(element): boolean {
          return element.id === input.id
        }
        const found = userConfig.hdmiInputs.findIndex((x) => fn(x))
        if (found === -1) {
          this.log.info(
            "unsetting HDMI input '%s' ['%s'] since it was dropped from the config.json",
            input.id,
            input.name
          )
        } else {
          shallow.push(input)
        }
      })
      this.storage.data.inputs.hdmi = [...shallow]
      this.storage.data.ipAddress = this.userConfig.ipAddress
      this.storage.data.specs = { ...this.device.specs }

      // FIXME: check also for added/removed apps (just in case)
    }

    // TV Tuner
    this.configureInputSource('TUNER', 'TV Tuner', 500)
    // HDMI inputs ...
    this.storage.data.inputs.hdmi.forEach((input) => {
      const sig = Number.parseInt(input.id, 10)
      this.configureInputSource('HDMI', input.name, sig)
    })
    // Apps
    Object.entries(this.storage.data.inputs.applications).forEach(
      /* eslint-disable-next-line @typescript-eslint/no-explicit-any */
      (line: any) => {
        const [id, app] = line
        const sig = 1000 + Number.parseInt(id, 10)
        this.configureInputSource('APPLICATION', app.name, sig)
      }
    )
  }

  private async setInput(
    value: CharacteristicValue,
    callback: CharacteristicSetCallback
  ): Promise<void> {
    const fn = async (): Promise<Outcome<void>> => {
      let app
      let real: number

      switch (false) {
        case !(value < 100):
          this.log.debug('(setInput) switching to HDMI INPUT ', value)
          return await this.device.sendHDMICommand((value as number).toString())
        case !(value > 999):
          real = (value as number) - 1000
          app = this.storage.data.inputs.applications[real]
          this.log.debug('(setInput) switching to App', app.name)
          return await this.device.sendAppCommand(app.id)
        case !(value === 500):
        default:
          this.log.debug('(setInput) switching to internal TV tunner')
          return await this.device.sendCommand('AD_CHANGE')
      }
    }

    const cmd = await fn()
    if (Abnormal(cmd)) {
      this.log.error('setInput', value, cmd.error)
    }
    callback(undefined, value)
  }

  private configureInputSource(
    type: InputType,
    configuredName: string,
    identifier: number
  ): void {
    const fn = function isThere(element): boolean {
      return element.id === identifier.toString()
    }
    const visibility = (): string => {
      let idx: number
      let hidden: string
      const { inputs } = this.storage.data

      switch (type) {
        case 'HDMI':
          idx = inputs.hdmi.findIndex((x) => fn(x))
          hidden = inputs.hdmi[idx].hidden
          break
        case 'APPLICATION':
          idx = identifier - 1000
          hidden = inputs.applications[idx].hidden
          break
        case 'TUNER':
        default:
          hidden = inputs.TUNER.hidden
      }
      return hidden
    }

    const source = this.accessory.addService(
      this.Service.InputSource,
      displayName(configuredName),
      identifier
    )
    const visibilityState = (
      state: CharacteristicValue,
      callback: CharacteristicSetCallback
    ): void => {
      let idx: number
      const id =
        source.getCharacteristic(this.Characteristic.Identifier).value ?? 500
      const { inputs } = this.storage.data

      switch (false) {
        case !(id < 100):
          // hdmi input
          idx = inputs.hdmi.findIndex((x) => fn(x))
          inputs.hdmi[idx].hidden = state
          break
        case !(id > 999):
          // APP
          idx = (id as number) - 1000
          inputs.applications[idx].hidden = state
          break
        case !(id === 500):
        default:
          inputs.TUNER.hidden = state
          break
      }
      source
        .getCharacteristic(this.Characteristic.CurrentVisibilityState)
        .updateValue(state)
      return callback()
    }
    const hidden = visibility()

    source
      .setCharacteristic(
        this.Characteristic.InputSourceType,
        this.Characteristic.InputSourceType[type]
      )
      .setCharacteristic(this.Characteristic.CurrentVisibilityState, hidden)
      .setCharacteristic(this.Characteristic.TargetVisibilityState, hidden)
      .setCharacteristic(this.Characteristic.Identifier, identifier)
      .setCharacteristic(this.Characteristic.ConfiguredName, configuredName)
      .setCharacteristic(
        this.Characteristic.IsConfigured,
        this.Characteristic.IsConfigured.CONFIGURED
      )
    source
      .getCharacteristic(this.Characteristic.TargetVisibilityState)
      .on('set', visibilityState)

    const svc = this.accessory.getService(this.Service.Television)
    if (svc != null) {
      svc.addLinkedService(source)
    }
  }

  async setPowerStatus(
    nextState: CharacteristicValue,
    callback: CharacteristicSetCallback
  ): Promise<void> {
    const message =
      nextState === this.Characteristic.Active.ACTIVE ? 'ON' : 'into STANDBY'
    const currentState = await this.device.isTurnedOn()
    this.log.debug('(setPowerStatus)', nextState, currentState)
    if ((nextState === this.Characteristic.Active.ACTIVE) === currentState) {
      this.log.debug('TV is already %s: Ignoring!', message)
    } else if (
      nextState === this.Characteristic.Active.ACTIVE &&
      this.device.mac != null
    ) {
      this.log.debug('sending WOL packets to awake TV')
      await wakeOnLan(this.device.mac, { packets: 10 })
      await this.updateTVstatus(nextState)
      this.log.debug('Turned TV', message)
    } else {
      const cmd = await this.device.sendCommand('POWER')
      if (Abnormal(cmd)) {
        this.log.error(
          '(setPowerStatus)/-> %s  - unable to power cycle TV - probably unpowered',
          message
        )
      } else {
        await this.updateTVstatus(nextState)
        this.log.debug('Turned TV', message)
      }
    }

    callback()
  }

  async getPowerStatus(callback?: CharacteristicGetCallback): Promise<void> {
    const currentState = await this.device.isTurnedOn()

    await this.updateTVstatus(currentState)

    if (callback != null) {
      callback(undefined, currentState)
    }
  }

  async getMute(callback: CharacteristicGetCallback): Promise<void> {
    const state = await this.device.isTurnedOn()
    let mute: boolean

    if (state) {
      const cmd = await this.device.getMute()
      mute = !Abnormal(cmd) ? cmd.value : true
    } else {
      mute = true
    }
    this.log.debug('(getMute) is', mute)
    callback(undefined, mute)
  }

  async setMute(
    state: CharacteristicValue,
    callback: CharacteristicSetCallback
  ): Promise<void> {
    this.log.debug('(setMute) is', state)
    const cmd = await this.device.setMute(state as boolean)
    if (Abnormal(cmd)) {
      this.log.error(
        '(setMute)/(%s) unable to change mute state on TV...',
        state
      )
    } else {
      state = !(state as boolean)
    }
    callback(undefined, state)
  }

  async setVolume(
    value: CharacteristicValue,
    callback: CharacteristicSetCallback
  ): Promise<void> {
    this.log.debug('(setVolume)', value)
    const cmd = await this.device.setVolume((value as number).toString())
    if (Abnormal(cmd)) {
      this.log.error('(setVolume)/(%s) unable to set volume on TV...', value)
      value = 0
    }
    callback(undefined, value)
  }

  async getVolume(callback: CharacteristicSetCallback): Promise<void> {
    const cmd = await this.device.getVolume()
    let volume: number
    if (Abnormal(cmd)) {
      this.log.error('(getVolume) unable to get volume from TV...')
      volume = 0
    } else {
      volume = Number(cmd.value)
    }

    callback(undefined, volume)
  }

  async setVolumeSelector(
    key: CharacteristicValue,
    callback: CharacteristicSetCallback
  ): Promise<void> {
    this.log.debug('setVolumeSelector', key)
    const action =
      key === this.Characteristic.VolumeSelector.INCREMENT ? 'VOLUP' : 'VOLDOWN'
    const cmd = await this.device.sendCommand(action)

    if (Abnormal(cmd)) {
      this.log.error('(setVolumeSelector) unable to change volume', cmd.error)
    }

    callback()
  }

  async updateTVstatus(newState: CharacteristicValue): Promise<void> {
    let customSpeakerService: Service | undefined
    const tvService = this.accessory.getService(this.Service.Television)
    const speakerService = this.accessory.getService(
      this.Service.TelevisionSpeaker
    )

    if (tvService === undefined || speakerService === undefined) {
      return
    }

    if (this.userConfig.customVolumeSlider === true) {
      customSpeakerService = this.accessory.getService(this.Service.Fan)
    }

    speakerService
      .getCharacteristic(this.Characteristic.Active)
      .updateValue(newState)
    tvService
      .getCharacteristic(this.Characteristic.Active)
      .updateValue(newState)
    if (newState === true) {
      const cmd = await this.device.getMute()
      if (
        !Abnormal(cmd) &&
        cmd.value !==
          speakerService.getCharacteristic(this.Characteristic.Mute).value
      ) {
        speakerService
          .getCharacteristic(this.Characteristic.Mute)
          .updateValue(cmd.value)
        if (customSpeakerService != null) {
          customSpeakerService
            .getCharacteristic(this.Characteristic.On)
            .updateValue(cmd.value ? 0 : 1)
        }
      }
    } else {
      speakerService
        .getCharacteristic(this.Characteristic.Mute)
        .updateValue(true)

      if (customSpeakerService != null) {
        customSpeakerService
          .getCharacteristic(this.Characteristic.On)
          .updateValue(false)
      }
    }
  }

  async remoteControl(
    keyId: CharacteristicValue,
    callback: CharacteristicSetCallback
  ): Promise<void> {
    let action: string
    //  https://github.com/KhaosT/HAP-NodeJS/blob/master/src/lib/gen/HomeKit-TV.ts#L235
    switch (keyId) {
      // Rewind
      case 0:
        action = 'REW'
        break
      // Fast Forward
      case 1:
        action = 'FF'
        break
      // Next Track
      case 2:
        action = 'SKIP_NEXT'
        break
      // Previous Track
      case 3:
        action = 'SKIP_PREV'
        break
      // Up Arrow
      case 4:
        action = 'UP'
        break
      // Down Arrow
      case 5:
        action = 'DOWN'
        break
      // Left Arrow
      case 6:
        action = 'LEFT'
        break
      // Right Arrow
      case 7:
        action = 'RIGHT'
        break
      // Select
      case 8:
        action = 'ENTER'
        break
      // Back
      case 9:
        action = 'RETURN'
        break
      // Exit
      case 10:
        action = 'CANCEL'
        break
      // Play / Pause
      case 11:
        action = 'PLAY'
        break
      // Information
      case 15:
      default:
        action = 'HOME'
        break
    }
    this.log.debug('remote control:', action)
    const cmd = await this.device.sendCommand(action)

    if (Abnormal(cmd)) {
      this.log.error('(remoteControl)/(%s) %s', action, cmd.error)
    }

    callback(undefined, keyId)
  }
}

export { sleep, UserConfig, VieramaticPlatformAccessory }
