class ChatGroup {
  final String id;
  final String name;
  final List<String> memberUids;

  const ChatGroup({
    required this.id,
    required this.name,
    required this.memberUids,
  });

  ChatGroup copyWith({
    String? name,
    List<String>? memberUids,
  }) {
    return ChatGroup(
      id: id,
      name: name ?? this.name,
      memberUids: memberUids ?? this.memberUids,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'member_uids': memberUids,
      };

  factory ChatGroup.fromJson(Map<String, dynamic> j) => ChatGroup(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Group',
        memberUids: List<String>.from(j['member_uids'] as List? ?? const []),
      );
}
