class RemotePingResult {
  const RemotePingResult({
    required this.isOnline,
    required this.latencyMs,
    this.hostname = '',
    this.engine = '',
    this.lanIps = const [],
    this.errorMessage = '',
  });

  final bool isOnline;
  final int latencyMs;
  final String hostname;
  final String engine;
  final List<String> lanIps;
  final String errorMessage;
}
