class FetchException implements Exception {
  FetchException({
    required this.message,
    this.isOffline = false,
    this.cause,
  });

  final String message;
  final bool isOffline;
  final Object? cause;

  @override
  String toString() => 'FetchException($message, offline=$isOffline)';
}
