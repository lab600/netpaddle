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

import 'package:flutter/material.dart';
import 'package:flame/components.dart';
import 'package:logging/logging.dart';
import 'pixel_mapper.dart';
import 'game.dart';

/// Component for the paddle used by player or opponent.
class Pad extends PositionComponent with HasGameRef<PaddleGame> {
  static final log = Logger("Pad");

  // all position and sizing are ratio of screen dimension i.e. btw 0 to 1
  // to allow easy device independent rendering and compatibility
  static const double normWidth = 0.25;
  static const double normHeight = 0.02;
  static const double initNormYMargin = .15;
  static const double speedNormX = 1; // cover full width of screen in 1 sec

  final bool isPlayer;

  double _vx = 0; // either -SPEED_X, 0, +SPEED_X
  late PixelMapper _pxMap;

  Pad({gameWidth = 0, gameHeight = 0, this.isPlayer = true}) : super() {
    anchor = Anchor.center;
    _pxMap = PixelMapper(gameWidth: gameWidth, gameHeight: gameHeight);
    reset();
  }

  double get vx => _vx;

  void reset() {
    scale = Vector2(1, 1);
    position = _pxMap.toDevPos(0.5, isPlayer ? 1 - initNormYMargin : initNormYMargin);
    size = _pxMap.toDevDim(normWidth, normHeight);
  }

  @override
  void onGameResize(Vector2 size) {
    final normX = _pxMap.toNormX(x);
    final normY = _pxMap.toNormY(y);
    final normVX = _pxMap.toNormWth(vx);

    super.onGameResize(size);

    _pxMap = PixelMapper(gameWidth: size.x, gameHeight: size.y);
    x = _pxMap.toDevX(normX);
    y = _pxMap.toDevY(normY);
    _vx = _pxMap.toDevWth(normVX);
    width = _pxMap.toDevWth(normWidth);
    height = _pxMap.toDevHgt(normHeight);
  }

  @override
  void render(Canvas canvas) {
    final padPaint = Paint();
    padPaint.color = isPlayer ? Colors.blue : Colors.red;
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), padPaint);
    super.render(canvas);
  }

  @override
  void update(double dt) {
    super.update(dt);

    // regardless of mode, player always control self pad
    if (isPlayer) {
      x = (x + dt * vx).clamp(
        gameRef.leftMargin,
        gameRef.rightMargin,
      );
    } else if (gameRef.isSingle) {
      // computer controls opponent, go to direction of ball
      if (gameRef.ball.x > (x + .3 * width)) {
        _vx = _pxMap.toDevWth(speedNormX);
      } else if (gameRef.ball.x < (x - .3 * width)) {
        _vx = -_pxMap.toDevWth(speedNormX);
      } else {
        _vx = 0;
      }
      x = (x + dt * vx).clamp(
        gameRef.leftMargin,
        gameRef.rightMargin,
      );
    } // let remote host set opponent position
  }

  void moveLeft() {
    _vx = -_pxMap.toDevWth(speedNormX);
  }

  void moveRight() {
    _vx = _pxMap.toDevWth(speedNormX);
  }

  void setStationary() {
    _vx = 0;
  }

  void setX(double newX) {
    x = newX;
  }

  // see if pad touches the normalized rectangle
  bool touch(Rect normRect) {
    return toAbsoluteRect().overlaps(normRect);
  }
}
