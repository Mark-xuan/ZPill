/// Z30 STA JPEG transfer settings captured once per app launch.
enum Z30TransferProfile {
  normal(0),
  fixed512(512),
  fixed1024(1024),
  fixed2048(2048),
  highspeed(1024);

  const Z30TransferProfile(this.chunkKiB);

  final int chunkKiB;
  bool get highSpeed => this == highspeed;
  bool get bypassOriginalCache => this != normal;
}
