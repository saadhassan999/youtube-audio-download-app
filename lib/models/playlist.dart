class Playlist {
  final int? id;
  final String name;

  Playlist({this.id, required this.name});

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
  };

  factory Playlist.fromMap(Map<String, dynamic> map) => Playlist(
    id: map['id'],
    name: map['name'],
  );
} 