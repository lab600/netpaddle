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

// This is a basic Flutter widget test to make sure app launches
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/material.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:netpaddle/game.dart';

final fixedGameSize = Vector2(
  400,
  800,
);

void main() {
  group('Game Tests', () {
    //Define what should run before and after each test
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    tearDown(() {});

    testWithFlameGame('game widget can be created', (game) async {
      await game.ready();
      expect(find.byGame<PaddleGame>(), findsOneWidget);
    });

    // some how overlay not visible
    testWithFlameGame('game main menu has right buttons on launch', (game) async {
      await game.ready();
      expect(find.widgetWithText(ElevatedButton, 'Single Player'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Host Network Game'), findsOneWidget);
    });
  });
}
