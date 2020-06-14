//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
}

class AVPlayerWrapper: AVPlayerWrapperProtocol {
    
    struct Constants {
        static let assetPlayableKey = "playable"
    }
    
    // MARK: - Properties
    
    var avPlayer: AVPlayer
	var assetURL: URL
	var loopObserver: Any
    let playerObserver: AVPlayerObserver
    let playerTimeObserver: AVPlayerTimeObserver
    let playerItemNotificationObserver: AVPlayerItemNotificationObserver
    let playerItemObserver: AVPlayerItemObserver
	
    /**
     True if the last call to load(from:playWhenReady) had playWhenReady=true.
     */
    fileprivate var _playWhenReady: Bool = true
    fileprivate var _initialTime: TimeInterval?
    
    fileprivate var _state: AVPlayerWrapperState = AVPlayerWrapperState.idle {
        didSet {
            if oldValue != _state {
                self.delegate?.AVWrapper(didChangeState: _state)
            }
        }
    }
    
    public init() {
        self.avPlayer = AVPlayer()
        self.playerObserver = AVPlayerObserver()
        self.playerObserver.player = avPlayer
        self.playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: timeEventFrequency.getTime())
        self.playerTimeObserver.player = avPlayer
        self.playerItemNotificationObserver = AVPlayerItemNotificationObserver()
        self.playerItemObserver = AVPlayerItemObserver()
		self.assetURL = URL(fileURLWithPath: "")
		self.loopObserver = AVPlayerObserver()
		
        self.playerObserver.delegate = self
        self.playerTimeObserver.delegate = self
        self.playerItemNotificationObserver.delegate = self
        self.playerItemObserver.delegate = self

        playerTimeObserver.registerForPeriodicTimeEvents()
    }
    
    // MARK: - AVPlayerWrapperProtocol
    
    var state: AVPlayerWrapperState {
        return _state
    }
    
    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        return avPlayer.reasonForWaitingToPlay
    }
    
    var currentItem: AVPlayerItem? {
        return avPlayer.currentItem
    }
    
    var _pendingAsset: AVAsset? = nil
    
    var automaticallyWaitsToMinimizeStalling: Bool {
        get { return avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }
    
    var currentTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }
    
    var duration: TimeInterval {
        if let seconds = currentItem?.asset.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.loadedTimeRanges.first?.timeRangeValue.duration.seconds,
            !seconds.isNaN {
            return seconds
        }
        return 0.0
    }
    
    var bufferedPosition: TimeInterval {
        return currentItem?.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? 0
    }
    
    weak var delegate: AVPlayerWrapperDelegate? = nil
    
    var bufferDuration: TimeInterval = 0
    
    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }
    
    var rate: Float {
        get { return avPlayer.rate }
        set { avPlayer.rate = newValue }
    }
    
    var volume: Float {
        get { return avPlayer.volume }
        set { avPlayer.volume = newValue }
    }
    
    var isMuted: Bool {
        get { return avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }
    
	func getFadeItem() -> AVPlayerItem  {
		if let asset = self._pendingAsset {
			let item = AVPlayerItem(asset: asset)
			let duration = asset.duration
			let durationInSeconds = CMTimeGetSeconds(duration)
			let params = AVMutableAudioMixInputParameters(track: asset.tracks.first! as AVAssetTrack)

			let firstSecond = CMTimeRangeMake(start: CMTimeMakeWithSeconds(0, preferredTimescale: 1), duration: CMTimeMakeWithSeconds(1, preferredTimescale: 1))
			let lastSecond = CMTimeRangeMake(start: CMTimeMakeWithSeconds(durationInSeconds-1, preferredTimescale: 1), duration: CMTimeMakeWithSeconds(1, preferredTimescale: 1))

			params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: firstSecond)
			params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: lastSecond)
			
			let mix = AVMutableAudioMix()
			mix.inputParameters = [params]
			item.audioMix = mix
			
			loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
				self?.avPlayer.seek(to: CMTime.zero)
				self?.avPlayer.play()
			}
			return item
		}
		let asset = AVAsset.init(url: self.assetURL) as AVAsset
		return AVPlayerItem(asset: asset)
	}
	
    func play() {
		// Item with fade in/out and loop
		let item = self.getFadeItem()
		avPlayer.replaceCurrentItem(with: item)
		avPlayer.play()
    }
    
    func pause() {
		// Remove observer for loops
		NotificationCenter.default.removeObserver(loopObserver, name: .AVPlayerItemDidPlayToEndTime, object: self.avPlayer.currentItem)
        avPlayer.pause()
    }
    
    func togglePlaying() {
        switch avPlayer.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            pause()
        case .paused:
            play()
        @unknown default:
            fatalError("Unknown AVPlayer.timeControlStatus")
        }
    }
    
    func stop() {
        pause()
        reset(soft: false)
    }
    
    func seek(to seconds: TimeInterval) {
        avPlayer.seek(to: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)) { (finished) in
            if let _ = self._initialTime {
                self._initialTime = nil
                if self._playWhenReady {
                    self.play()
                }
            }
            self.delegate?.AVWrapper(seekTo: Int(seconds), didFinish: finished)
        }
    }
    
    
    
    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        reset(soft: true)
        _playWhenReady = playWhenReady

        if currentItem?.status == .failed {
            recreateAVPlayer()
        }
        
        self._pendingAsset = AVURLAsset(url: url, options: options)
        
        if let pendingAsset = _pendingAsset {
            self._state = .loading
            pendingAsset.loadValuesAsynchronously(forKeys: [Constants.assetPlayableKey], completionHandler: { [weak self] in
                
                guard let self = self else {
                    return
                }
                
                var error: NSError? = nil
                let status = pendingAsset.statusOfValue(forKey: Constants.assetPlayableKey, error: &error)
                
                DispatchQueue.main.async {
                    let isPendingAsset = (self._pendingAsset != nil && pendingAsset.isEqual(self._pendingAsset))
                    switch status {
                    case .loaded:
                        if isPendingAsset {
                            let currentItem = AVPlayerItem(asset: pendingAsset, automaticallyLoadedAssetKeys: [Constants.assetPlayableKey])
                            currentItem.preferredForwardBufferDuration = self.bufferDuration
                            self.avPlayer.replaceCurrentItem(with: currentItem)
                            
                            // Register for events
                            self.playerTimeObserver.registerForBoundaryTimeEvents()
                            self.playerObserver.startObserving()
                            self.playerItemNotificationObserver.startObserving(item: currentItem)
                            self.playerItemObserver.startObserving(item: currentItem)
                        }
                        break
                        
                    case .failed:
                        if isPendingAsset {
                            self.delegate?.AVWrapper(failedWithError: error)
                            self._pendingAsset = nil
                        }
                        break
                        
                    case .cancelled:
                        break
                        
                    default:
                        break
                    }
                }
            })
        }
    }
    
    func load(from url: URL, playWhenReady: Bool, initialTime: TimeInterval? = nil, options: [String : Any]? = nil) {
        _initialTime = initialTime
        self.pause()
		self.assetURL = url
        self.load(from: url, playWhenReady: playWhenReady, options: options)
    }
    
    // MARK: - Util
    
    private func reset(soft: Bool) {
        playerItemObserver.stopObservingCurrentItem()
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerItemNotificationObserver.stopObservingCurrentItem()
        
        self._pendingAsset?.cancelLoading()
        self._pendingAsset = nil
        
        if !soft {
            avPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    /// Will recreate the AVPlayer instance. Used when the current one fails.
    private func recreateAVPlayer() {
        let player = AVPlayer()
        playerObserver.player = player
        playerTimeObserver.player = player
        playerTimeObserver.registerForPeriodicTimeEvents()
        avPlayer = player
        delegate?.AVWrapperDidRecreateAVPlayer()
    }
    
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {
    
    // MARK: - AVPlayerObserverDelegate
    
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        switch status {
        case .paused:
            if currentItem == nil {
                _state = .idle
            }
            else {
                self._state = .paused
            }
        case .waitingToPlayAtSpecifiedRate:
            self._state = .buffering
        case .playing:
            self._state = .playing
        @unknown default:
            break
        }
    }
    
    func player(statusDidChange status: AVPlayer.Status) {
        switch status {
        case .readyToPlay:
            self._state = .ready
            if _playWhenReady && (_initialTime ?? 0) == 0 {
                self.play()
            }
            else if let initialTime = _initialTime {
                self.seek(to: initialTime)
            }
            break
            
        case .failed:
            self.delegate?.AVWrapper(failedWithError: avPlayer.error)
            break
            
        case .unknown:
            break
        @unknown default:
            break
        }
    }
    
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {
    
    // MARK: - AVPlayerTimeObserverDelegate
    
    func audioDidStart() {
        self._state = .playing
    }
    
    func timeEvent(time: CMTime) {
        self.delegate?.AVWrapper(secondsElapsed: time.seconds)
    }
    
}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    
    // MARK: - AVPlayerItemNotificationObserverDelegate
    
    func itemDidPlayToEndTime() {
        delegate?.AVWrapperItemDidPlayToEndTime()
    }
    
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    
    // MARK: - AVPlayerItemObserverDelegate
    
    func item(didUpdateDuration duration: Double) {
        self.delegate?.AVWrapper(didUpdateDuration: duration)
    }
    
}
