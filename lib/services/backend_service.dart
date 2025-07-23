import 'package:http/http.dart' as http;
import 'dart:convert';

class BackendService {
  static Future<String> requestAudio(String videoId) async {
    final response = await http.post(
      Uri.parse('https://your-backend.com/api/convert'),
      body: jsonEncode({'videoId': videoId}),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['audioUrl'];
    } else {
      throw Exception('Backend conversion failed');
    }
  }
} 