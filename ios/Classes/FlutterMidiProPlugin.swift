import Flutter
import CoreMIDI
import AVFAudio
import AVFoundation
import CoreAudio

public class FlutterMidiProPlugin: NSObject, FlutterPlugin {
    // Properties to manage audio engines, samplers and soundfonts
    var audioEngines: [Int: [AVAudioEngine]] = [:]
    var soundfontIndex = 1
    var soundfontSamplers: [Int: [AVAudioUnitSampler]] = [:]
    var soundfontURLs: [Int: URL] = [:]
    
    // Track the running state of audio engines
    private var isAudioEngineRunning = false
    
    // Event channel for audio interruption notifications
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_midi_pro", binaryMessenger: registrar.messenger())
        let instance = FlutterMidiProPlugin()
        
        // Setup event channel for interruption notifications
        instance.eventChannel = FlutterEventChannel(name: "flutter_midi_pro_events", binaryMessenger: registrar.messenger())
        instance.eventChannel?.setStreamHandler(instance)
        
        // Register for audio session interruption notifications
        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(instance.handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil)
        
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    /// Handles audio session interruptions (e.g., phone calls, alarms)
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt else {
            return
        }
        
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        
        switch type {
        case .began:
            // Pause all audio engines when interruption begins
            audioEngines.forEach { (_, engines) in
                engines.forEach { $0.pause() }
            }
            isAudioEngineRunning = false
            // Notify Flutter about interruption
            eventSink?(["event": "audioInterrupted", "interrupted": true])
            
        case .ended:
            // Restart all audio engines after interruption
            audioEngines.forEach { (_, engines) in
                engines.forEach { engine in
                    do {
                        try engine.start()
                    } catch {
                        print("Failed to restart audio engine after interruption: \(error)")
                    }
                }
            }
            isAudioEngineRunning = true
            // Notify Flutter about interruption ended
            eventSink?(["event": "audioInterrupted", "interrupted": false])
            
        default:
            break
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "loadSoundfont":
            // Load a soundfont file and initialize audio engines for all 16 MIDI channels
            let args = call.arguments as! [String: Any]
            let path = args["path"] as! String
            let bank = args["bank"] as! Int
            let program = args["program"] as! Int
            let url = URL(fileURLWithPath: path)
            var chSamplers: [AVAudioUnitSampler] = []
            var chAudioEngines: [AVAudioEngine] = []
            
            // Create 16 samplers for 16 MIDI channels
            for _ in 0...15 {
                let sampler = AVAudioUnitSampler()
                let audioEngine = AVAudioEngine()
                audioEngine.attach(sampler)
                audioEngine.connect(sampler, to: audioEngine.mainMixerNode, format:nil)
                
                // Configure and start the audio session
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                    try AVAudioSession.sharedInstance().setActive(true)
                    try audioEngine.start()
                    isAudioEngineRunning = true
                } catch {
                    result(FlutterError(code: "AUDIO_ENGINE_START_FAILED", message: "Failed to start audio engine", details: nil))
                    return
                }
                
                // Load the soundfont instrument
                do {
                    try sampler.loadSoundBankInstrument(at: url, program: UInt8(program), bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(bank))
                } catch {
                    result(FlutterError(code: "SOUND_FONT_LOAD_FAILED", message: "Failed to load soundfont", details: nil))
                    return
                }
                chSamplers.append(sampler)
                chAudioEngines.append(audioEngine)
            }
            
            // Store the created samplers and engines
            soundfontSamplers[soundfontIndex] = chSamplers
            soundfontURLs[soundfontIndex] = url
            audioEngines[soundfontIndex] = chAudioEngines
            soundfontIndex += 1
            result(soundfontIndex-1)
            
        case "selectInstrument":
            // Change the instrument for a specific channel
            let args = call.arguments as! [String: Any]
            let sfId = args["sfId"] as! Int
            let channel = args["channel"] as! Int
            let bank = args["bank"] as! Int
            let program = args["program"] as! Int
            let soundfontSampler = soundfontSamplers[sfId]![channel]
            let soundfontUrl = soundfontURLs[sfId]!
            do {
                try soundfontSampler.loadSoundBankInstrument(at: soundfontUrl, program: UInt8(program), bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(bank))
            } catch {
                result(FlutterError(code: "SOUND_FONT_LOAD_FAILED", message: "Failed to load soundfont", details: nil))
                return
            }
            soundfontSampler.sendProgramChange(UInt8(program), bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(bank), onChannel: UInt8(channel))
            result(nil)
        case "playNote":
            // Play a MIDI note on a specific channel
            let args = call.arguments as! [String: Any]
            let channel = args["channel"] as! Int
            let note = args["key"] as! Int
            let velocity = args["velocity"] as! Int
            let sfId = args["sfId"] as! Int
            let soundfontSampler = soundfontSamplers[sfId]![channel]
            soundfontSampler.startNote(UInt8(note), withVelocity: UInt8(velocity), onChannel: UInt8(channel))
            result(nil)
        case "stopNote":
            // Stop a MIDI note on a specific channel
            let args = call.arguments as! [String: Any]
            let channel = args["channel"] as! Int
            let note = args["key"] as! Int
            let sfId = args["sfId"] as! Int
            let soundfontSampler = soundfontSamplers[sfId]![channel]
            soundfontSampler.stopNote(UInt8(note), onChannel: UInt8(channel))
            result(nil)
        case "unloadSoundfont":
            // Unload a soundfont and clean up its resources
            let args = call.arguments as! [String:Any]
            let sfId = args["sfId"] as! Int
            let soundfontSampler = soundfontSamplers[sfId]
            if soundfontSampler == nil {
                result(FlutterError(code: "SOUND_FONT_NOT_FOUND", message: "Soundfont not found", details: nil))
                return
            }
            audioEngines[sfId]?.forEach { (audioEngine) in
                audioEngine.stop()
            }
            audioEngines.removeValue(forKey: sfId)
            soundfontSamplers.removeValue(forKey: sfId)
            soundfontURLs.removeValue(forKey: sfId)
            result(nil)
        case "dispose":
            // Clean up all resources when the plugin is disposed
            audioEngines.forEach { (key, value) in
                value.forEach { (audioEngine) in
                    audioEngine.stop()
                }
            }
            audioEngines = [:]
            soundfontSamplers = [:]
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
            break
        }
    }
    
    /// Clean up observers when the plugin is deallocated
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - FlutterStreamHandler
extension FlutterMidiProPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
