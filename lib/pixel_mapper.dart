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
import 'dart:ui';
import 'package:vector_math/vector_math_64.dart';

/// Util to figure out actual device resolution and mapping of game position
class PixelMapper {
  static const NORM_PADDING = 0.05;

  late final double pixelRatio;
  late final Size physicalScreenSize;
  late final double physicalWidth;
  late final double physicalHeight;
  late final Size logicalScreenSize;
  late final double logicalWidth;
  late final double logicalHeight;
  late final double paddingLeft;
  late final double paddingRight;
  late final double paddingTop;
  late final double paddingBottom;
  late final double safeWidth;
  late final double safeHeight;

  PixelMapper({gameWidth: 0, gameHeight: 0}) {
    if (gameWidth > 0 && gameHeight > 0) {
      pixelRatio = 1;
      physicalScreenSize = Size(gameWidth, gameHeight);
      physicalWidth = gameWidth;
      physicalHeight = gameHeight;
      logicalScreenSize = physicalScreenSize;
      logicalWidth = physicalWidth;
      logicalHeight = physicalHeight;

      paddingLeft = NORM_PADDING * logicalWidth;
      paddingRight = paddingLeft;
      paddingTop = NORM_PADDING * logicalHeight;
      paddingBottom = paddingTop;
    } else {
      pixelRatio = window.devicePixelRatio;

      //Size in physical pixels
      physicalScreenSize = window.physicalSize;
      physicalWidth = physicalScreenSize.width;
      physicalHeight = physicalScreenSize.height;

      //Size in logical pixels
      logicalScreenSize = window.physicalSize / pixelRatio;
      logicalWidth = logicalScreenSize.width;
      logicalHeight = logicalScreenSize.height;

      //Padding in physical pixels
      WindowPadding padding = window.padding;

      //Safe area paddings in logical pixels
      paddingLeft = padding.left / pixelRatio;
      paddingRight = padding.right / pixelRatio;
      paddingTop = padding.top / pixelRatio;
      paddingBottom = padding.bottom / pixelRatio;
    }

    //Safe area in logical pixels
    safeWidth = logicalWidth - paddingLeft - paddingRight;
    safeHeight = logicalHeight - paddingTop - paddingBottom;
  }

  Vector2 get devSafeSize => Vector2(safeWidth, safeHeight);
  Vector2 get devCenter =>
      Vector2(paddingLeft + safeWidth / 2, paddingTop + safeHeight / 2);

  double toNormX(double devX) => (devX - paddingLeft) / safeWidth;
  double toNormY(double devY) => (devY - paddingTop) / safeHeight;
  double toDevX(double normX) => paddingLeft + normX * safeWidth;
  double toDevY(double normY) => paddingTop + normY * safeHeight;
  Vector2 toDevPos(double gameX, double gameY) =>
      Vector2(toDevX(gameX), toDevY(gameY));

  double toNormWth(double devWth) => devWth / safeWidth;
  double toNormHgt(double devHgt) => devHgt / safeHeight;
  double toDevWth(double normWth) => normWth * safeWidth;
  double toDevHgt(double normHgt) => normHgt * safeHeight;
  Vector2 toDevDim(double gameWth, double gameHgt) =>
      Vector2(toDevWth(gameWth), toDevHgt(gameHgt));

  double get maxDevDim => max(safeWidth, safeHeight);
}
