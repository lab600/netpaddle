// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import 'dart:typed_data';

import 'package:flame/flame.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'game.dart';

/// Main Starting Point of the Net Paddle game app.
void main() async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    print('${r.loggerName} ${r.level.name} ${r.time}: ${r.message}');
  });

  final log = Logger("main");

  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.bottom, SystemUiOverlay.top],
  );
  Flame.device.fullScreen();
  Flame.device.setOrientation(DeviceOrientation.portraitUp);

  final networkInfo = NetworkInfo();

  Uint8List? addressIPv4;
  if (!kIsWeb) {
    // if not running in Web try to get local IP address
    try {
      String? wifiName = await networkInfo.getWifiName();
      String? wifiIPv4 = await networkInfo.getWifiIP();
      log.info("Wifi IPv4 address is $wifiIPv4 on ${wifiName ?? 'network'}.");
      addressIPv4 =
          Uint8List.fromList(wifiIPv4!.split("\.").map(int.parse).toList());
    } on Exception catch (e) {
      log.warning('Failed to get Wifi IPv4 address', e);
      addressIPv4 = null;
    }
  }

  final game = PaddleGame(addressIPv4);
  runApp(GameWidget(game: game, overlayBuilderMap: game.overlayMap));
}
