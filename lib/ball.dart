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

import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flame/components.dart';
import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'pixel_mapper.dart';
import 'game.dart';
import 'constants.dart';

/// Ball component keep ball state and implement logic to calc and render pos
class Ball extends PositionComponent with HasGameRef<PaddleGame> {
  static final log = Logger("Ball");

  static const PAUSE_INTERVAL = 3.0; // pause in secs when a point is scored
  static const NORM_RAD = 0.01;
  static const NORM_SPEED = 0.3;
  static const NORM_SPIN = 0.3;

  final _rand = Random();

  late PixelMapper _pxMap;

  double _vx = 0.0;
  double _vy = 0.0;
  double _pause = 0.0;
  DateTime _lastHitTime = clock.now();
  bool forceNetSend = false;

  DateTime get lastHitTime => _lastHitTime;

  Ball({double gameWidth: 0, double gameHeight: 0}) : super() {
    _pxMap = PixelMapper(gameWidth: gameWidth, gameHeight: gameHeight);
    reset();
  }

  /// reset to a known position and vertical speed, horizontal speed 0.
  void reset({double normVY: NORM_SPEED, double normX: .5, double normY: .5}) {
    scale = Vector2(1, 1);
    anchor = Anchor.center;
    _pause = normVY <= 0 ? PAUSE_INTERVAL : 0.0;
    _vx = 0.0;
    _vy = _pxMap.toDevHgt(normVY);
    width = _pxMap.toDevHgt(2 * NORM_RAD);
    height = _pxMap.toDevHgt(2 * NORM_RAD);
    position = _pxMap.toDevPos(normX, normY);
  }

  bool get isPaused => _pause > 0;
  double get vx => _vx;
  double get vy => _vy;
  double get pause => _pause;
  double get radius => height / 2;
  double randSpin(double padVX) =>
      (padVX.sign + (_rand.nextDouble() - .5)) * NORM_SPIN * _pxMap.safeWidth;

  /// update ball position given time elapsed and current velocity.
  /// detect if hitting against walls or paddles,
  /// change velocity and score if needed.
  /// In network game, update ball if it's going towards the player's paddle.
  @override
  void update(double dt) {
    super.update(dt);
    if (gameRef.isOver || gameRef.isWaiting) return;

    // let opponent update states in network game if ball going away from me
    if (vy < 0 && !gameRef.isSingle) return;

    if (_pause > 0) {
      // if we are in a paused state, reduce the count down by elapsed time
      _pause = _pause - dt;
      x = y > gameRef.myPad.y - _pxMap.safeWidth / 3
          ? gameRef.myPad.x
          : gameRef.oppoPad.x;
      if (_pause <= 0) {
        // turn off forcing sending network updates at end of pause
        forceNetSend = false;
      }
    } else {
      x = (x + dt * vx).clamp(gameRef.leftMargin, gameRef.rightMargin);
      y = (y + dt * vy).clamp(gameRef.topMargin, gameRef.bottomMargin);
      final ballRect = toAbsoluteRect();
      if (x <= gameRef.leftMargin + radius) {
        // bounced left wall
        x = gameRef.leftMargin + radius;
        _vx = -vx;
      } else if (x >= gameRef.rightMargin - radius) {
        // bounced right wall
        x = gameRef.rightMargin - radius;
        _vx = -vx;
      }

      final now = clock.now();
      if (gameRef.myPad.touch(ballRect) && vy > 0) {
        _lastHitTime = now;
        FlameAudio.play(POP_FILE);
        y = gameRef.myPad.y - gameRef.myPad.height / 2 - 2 * radius;
        _vy = -vy;
        _vx += randSpin(gameRef.myPad.vx.sign);
        forceNetSend = true;
      } else if (y + radius >= gameRef.bottomMargin && vy > 0) {
        // bounced bottom
        _lastHitTime = now;
        _pause = PAUSE_INTERVAL;
        _vx = 0;
        _vy = -vy;
        y = gameRef.myPad.y - gameRef.myPad.height / 2 - 2 * radius;
        x = gameRef.myPad.x;
        gameRef.addOpponentScore();
        forceNetSend = true;
      }

      if (gameRef.isSingle) {
        if (gameRef.oppoPad.touch(ballRect) && vy < 0) {
          FlameAudio.play(POP_FILE);
          y = gameRef.oppoPad.y + gameRef.oppoPad.height / 2 + 2 * radius;
          _vy = -vy;
          _vx += randSpin(gameRef.myPad.vx.sign);
        } else if (y - radius <= gameRef.topMargin && vy < 0) {
          // bounced top
          _pause = PAUSE_INTERVAL;
          _vx = 0;
          _vy = -vy;
          y = gameRef.oppoPad.y + gameRef.oppoPad.height / 2 + 2 * radius;
          x = gameRef.oppoPad.x;
          gameRef.addMyScore();
        }
      }
    }
  }

  /// render the ball as a white filled circle
  @override
  void render(Canvas canvas) {
    final ballPaint = Paint();
    ballPaint.color = Colors.white;
    canvas.drawCircle(Offset(radius, radius), radius, ballPaint);
    super.render(canvas);
  }

  /// on resize, recalibrate the pixel mapper to match new dimensions
  @override
  void onGameResize(Vector2 gameSize) {
    final normX = _pxMap.toNormX(x);
    final normY = _pxMap.toNormY(y);

    super.onGameResize(gameSize);

    _pxMap = PixelMapper(gameWidth: gameSize.x, gameHeight: gameSize.y);
    x = _pxMap.toDevX(normX);
    y = _pxMap.toDevY(normY);
    _vx = 0;
    _vy = _pxMap.toDevHgt(NORM_SPEED);
    width = _pxMap.toDevWth(2 * NORM_RAD);
    height = _pxMap.toDevHgt(2 * NORM_RAD);
  }

  /// update ball position and velocity based on network update.
  /// the game object already vetted the validity.
  void updateOnReceive(
    double normX,
    double normY,
    double normVX,
    double normVY,
    double pauseCountDown,
  ) {
    _vx = -_pxMap.toDevWth(normVX);
    _vy = -_pxMap.toDevHgt(normVY);
    _pause = pauseCountDown;
    position = _pxMap.toDevPos(1.0 - normX, 1.0 - normY);
  }
}
