import 'package:flutter/material.dart';

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void showGlobalSnackBarMessage(String message) {
  showGlobalSnackBar(SnackBar(content: Text(message)));
}

void showGlobalSnackBar(SnackBar snackBar) {
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(snackBar);
}
