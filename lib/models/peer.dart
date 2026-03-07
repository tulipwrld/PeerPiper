// lib/models/peer.dart

class Peer {
  final String uid;
  final String name;
  final List<String> ips;
  final String xpub;

  /// True when the peer is currently reachable (promoted via Sybil challenge).
  /// False for peers loaded from saved history (offline).
  final bool isOnline;

  const Peer({
    required this.uid,
    required this.name,
    this.ips = const [],
    this.xpub = '',
    this.isOnline = false,
  });

  String? get ip => ips.isEmpty ? null : ips.first;
  String get shortUid => uid.length > 16 ? uid.substring(0, 16) : uid;
  String get displayName => '$name ($shortUid...)';

  Peer copyWith({
    List<String>? ips,
    String? xpub,
    bool? isOnline,
    String? name,
  }) =>
      Peer(
        uid: uid,
        name: name ?? this.name,
        ips: ips ?? this.ips,
        xpub: xpub ?? this.xpub,
        isOnline: isOnline ?? this.isOnline,
      );

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'name': name,
        'ips': ips,
        'xpub': xpub,
      };

  factory Peer.fromJson(Map<String, dynamic> j) => Peer(
        uid: j['uid'] as String,
        name: j['name'] as String? ?? 'Unknown',
        ips: List<String>.from(j['ips'] as List? ?? []),
        xpub: j['xpub'] as String? ?? '',
        isOnline: false,
      );

  @override
  bool operator ==(Object other) => other is Peer && other.uid == uid;

  @override
  int get hashCode => uid.hashCode;
}