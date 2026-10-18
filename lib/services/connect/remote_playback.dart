/// Playback happening on another device that this one controls (Diapason Connect).
///
/// While [forwarding], the player and the queue send what the user does to that device instead of acting on it
/// themselves, and show its state: the same screens drive local and remote playback, as with Spotify Connect.
abstract interface class RemotePlayback {
  /// The one in use, if any. Set by the Connect session.
  static RemotePlayback? current;

  static bool get isForwarding => current?.forwarding ?? false;

  /// A device is being controlled, and we are not in the middle of mirroring its queue locally.
  bool get forwarding;

  /// A device is being controlled (even while its queue is being mirrored).
  bool get active;

  bool get playing;

  /// The device's position, extrapolated since it last reported.
  Duration get position;

  double get volume;

  String? get deviceName;

  Future<void> play();

  Future<void> pause();

  Future<void> next();

  Future<void> previous();

  Future<void> seek(Duration position);

  Future<void> setVolume(double volume);

  /// [offset] is relative to the current track, as in `QueueService.skipByOffset`.
  Future<void> skipByOffset(int offset);

  /// A queue operation (see `ConnectPlayerBridge` for the actions); the mirrored queue follows once the device has
  /// applied it.
  Future<void> queueCommand(String action, [Map<String, dynamic> args = const {}]);

  /// Plays [items] (`BaseItemDto` JSON) there, replacing its queue.
  Future<void> playItems(
    List<Map<String, dynamic>> items, {
    required int startIndex,
    List<int>? shuffleOrder,
    bool shuffle = false,
  });
}
