//
//  RNTrackPlayerAudioPlayer.swift
//  RNTrackPlayer
//
//  Created by Dustin Bahr on 24/04/2020.
//

import Foundation
import MediaPlayer

/**
* An audio player that sends React Native events at appropriate times.
*
* This custom player was implemented to overcome issues that are caused by the
* asynchronous events emitted by SwiftAudio.
*
* Because these events are asynchronous, properties such as currentItem did not
* always contain the expected values. This led to events being sent to React
* Native with incorrect information.
*
* Additionally overriding the behavior of enableRemoteCommands fixes issues with
* lock screen controls.
*/

public class RNTrackPlayerAudioPlayer: QueuedAudioPlayer {

	public var reactEventEmitter: RCTEventEmitter
	public var currrentItems: [AudioItem]
	// Override _currentItem so that we can send an event when it changes.
	override var _currentItem: AudioItem? {
		willSet(newCurrentItem) {
			if ((newCurrentItem as? Track) === (_currentItem as? Track)) {
				return
			}

			self.reactEventEmitter.sendEvent(withName: "playback-track-changed", body: [
				"track": (_currentItem as? Track)?.id ?? nil,
				"position": self.currentTime,
				"nextTrack": (newCurrentItem as? Track)?.id ?? nil,
				])
		}
	}

	public var _players: Dictionary<String, AVAudioPlayer>
	public var _mainSoundId: String
	// Override init to include a reference to the React Event Emitter.
	public init(reactEventEmitter: RCTEventEmitter) {
        self.reactEventEmitter = reactEventEmitter
		self._players = Dictionary<String, AVAudioPlayer>()
		self._mainSoundId = ""
		self.currrentItems = [AudioItem]()
		super.init()
    }

	// MARK: - AVPlayerWrapperDelegate
    
    override func AVWrapper(didChangeState state: AVPlayerWrapperState) {
        super.AVWrapper(didChangeState: state)
		self.reactEventEmitter.sendEvent(withName: "playback-state", body: ["state": state.rawValue])
    }
    
    override func AVWrapper(failedWithError error: Error?) {
        super.AVWrapper(failedWithError: error)
        self.reactEventEmitter.sendEvent(withName: "playback-error", body: ["error": error?.localizedDescription])
    }
    
    override func AVWrapperItemDidPlayToEndTime() {
        if self.nextItems.count == 0 {
			// For consistency sake, send an event for the track changing to nothing
			self.reactEventEmitter.sendEvent(withName: "playback-track-changed", body: [
				"track": (self.currentItem as? Track)?.id ?? nil,
				"position": self.currentTime,
				"nextTrack": nil,
				])

			// fire an event for the queue ending
			self.reactEventEmitter.sendEvent(withName: "playback-queue-ended", body: [
				"track": (self.currentItem as? Track)?.id,
				"position": self.currentTime,
				])
		}
		super.AVWrapperItemDidPlayToEndTime()
    }

	func fromPathToTrack(path: String) -> String {
		// Retrieve sound name format: http://localhost:8081/path/to/asset/xxxx.mp3?id=xxx&hash=xxxx
		// Get xxxx.mp3?id=xxx&hash=xxxx
		var soundURL = path.split(separator: "/", maxSplits: 100, omittingEmptySubsequences: true).last
		// Get xxx.mp3
		soundURL = soundURL?.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: true).first
		// Get asset name
		soundURL = soundURL?.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: true).first
		return String(soundURL ?? "");
	}
	
	// MARK: - AudioPlayer
	override public func play() {
		if (queueManager.items.count > 1) {
			self.currrentItems.removeAll()
			self.currrentItems = queueManager.items
		}
		// Only first track is going through regular flow, we play the rest "manually"
		var skip = true
		for item in self.currrentItems {
			// Retrieve sound name format: http://localhost:8081/path/to/asset/xxxx.mp3?id=xxx&hash=xxxx
			let soundURL = fromPathToTrack(path: item.getSourceUrl());
			let title = item.getTitle() ?? ""
			if (soundURL.count == 0 || title.count == 0) {
				continue;
			}
			
			if skip {
				skip = false;
				self.volume = Float(item.getVolume())
				self._mainSoundId = title
				continue;
			}
			
			// Format name with path
			// WARNING: be careful to put your assets under "audio" folder,
			// Here it's the same audio asset file as the one in RN project
			let finalPath = String.init(format: "audio/%@", soundURL)
			let urlString = Bundle.main.path(forResource: finalPath, ofType: "mp3")
			let assetUrl = URL(fileURLWithPath: urlString!)
			do {
				if self._players[title] != nil {
					self._players[title]?.setVolume(Float(item.getVolume()), fadeDuration: 1000)
					self._players[title]?.play()
				} else {
					let audioPlayer = try AVAudioPlayer(contentsOf: assetUrl)
					self._players[title] = audioPlayer
					audioPlayer.volume = Float(item.getVolume())
					audioPlayer.play()
				}
			} catch {
				print(error.localizedDescription)
			}
		}
		super.play()
		clear()
	}

	func clear(soft: Bool = true) {
		if (!soft) {
			self._players.removeAll()
			self.currrentItems.removeAll()
		}
		queueManager.clearQueue()
		queueManager.removeUpcomingItems()
	}
	
	override public func pause() {
		for (_, player) in self._players {
			player.pause()
		}
		super.pause()
		clear()
	}
	
	override public func stop() {
		for (_, player) in self._players {
			player.stop()
		}
		super.stop()
		clear(soft: false)
	}
	
	func setVolumeForTrack(trackId: String, volume: Float) {
		if (trackId == self._mainSoundId) {
			self.volume = volume
			return
		}
		let currentPlayer = self._players[trackId]
		if (currentPlayer != nil) {
			currentPlayer?.setVolume(volume, fadeDuration: 0.25)
		}
	}
	// MARK: - Remote Command Center
    
	/**
	* Override this method in order to prevent re-enabling remote commands every
	* time a track loads.
	*
	* React Native Track Player does not use this feature of SwiftAudio which
	* allows defining remote commands per track.
	*
	* Because of the asychronous nature of controlling the queue from the JS
	* side, re-enabling commands in this way causes the lock screen controls to
	* behave poorly.
	*/
    override func enableRemoteCommands(forItem item: AudioItem) {
        if let item = item as? RemoteCommandable {
            self.enableRemoteCommands(item.getCommands())
        }
		else {
			// React Native Track Player does this manually in
			// RNTrackPlayer.updateOptions()
			// self.enableRemoteCommands(remoteCommands)
        }
    }
}
