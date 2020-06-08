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

	public var _players: [AVAudioPlayer];
	
	// Override init to include a reference to the React Event Emitter.
	public init(reactEventEmitter: RCTEventEmitter) {
        self.reactEventEmitter = reactEventEmitter
		self._players = [AVAudioPlayer]()
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

	// MARK: - AudioPlayer
	override public func play() {
		if self._players.count > 0 {
			for player in self._players {
				player.play()
			}
		}
		// Only first track is going through regular flow, we play the rest "manually"
		var skip = true
		for item in queueManager.items {
			if skip {
				skip = false;
				continue;
			}
			// Retrieve sound name format: http://localhost:8081/path/to/asset/xxxx.mp3?id=xxx&hash=xxxx
			let soundPath = item.getSourceUrl()
			// Get xxxx.mp3?id=xxx&hash=xxxx
			var soundURL = soundPath.split(separator: "/", maxSplits: 100, omittingEmptySubsequences: true).last
			// Get xxx.mp3
			soundURL = soundURL?.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: true).first
			// Get asset name
			soundURL = soundURL?.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: true).first
			// Format name with path
			// WARNING: be careful to put your assets under "audio" folder,
			// Here it's the same audio asset file as the one in RN project
			let finalPath = String.init(format: "audio/%@", String(soundURL!))
			let urlString = Bundle.main.path(forResource: finalPath, ofType: "mp3")
			let assetUrl = URL(fileURLWithPath: urlString!)
			do {
				let audioPlayer = try AVAudioPlayer(contentsOf: assetUrl)
				self._players.append(audioPlayer)
				audioPlayer.play()
			} catch {
				print(error.localizedDescription)
			}
		}
		super.play()
	}

	override public func pause() {
		for player in self._players {
			player.pause()
		}
		super.pause()
	}
	
	override public func stop() {
		for player in self._players {
			player.pause()
		}
		super.stop()
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
