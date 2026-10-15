import 'package:flutter/material.dart';

import 'app.dart';
import 'core/api_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(QuickBiteApp(apiClient: ApiClient()));
}
