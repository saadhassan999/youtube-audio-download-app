import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String kSupportEmail = 'saadhassan99950@gmail.com';

Future<void> openSupportEmail(BuildContext context) async {
  await copySupportEmail(context);
}

Future<void> copySupportEmail(BuildContext context) async {
  await Clipboard.setData(const ClipboardData(text: kSupportEmail));
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(const SnackBar(content: Text('Email copied')));
}
