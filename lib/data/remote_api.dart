import 'dart:async';

import 'package:narcis_nadzorniki/models/disturbance.dart';

class RemoteApi {
  Future<void> createRecord(Disturbance disturbance) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  Future<void> updateRecord(Disturbance disturbance) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  Future<void> deleteRecord(String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
