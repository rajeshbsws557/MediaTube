import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  try {
    final response = await dio.post(
      'https://api.cobalt.tools',
      data: {'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'},
      options: Options(headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      })
    );
    print(response.data);
  } catch (e) {
    if (e is DioException) {
      print('DioError: \${e.response?.statusCode} - \${e.response?.data}');
    } else {
      print(e);
    }
  }
}