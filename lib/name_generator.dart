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

import 'dart:typed_data';

/// Name Generator uses IP address or randomly generate a name for player
class NameGenerator {
  static const List<String> ANIMALS = [
    'Rat',
    'Cow',
    'Tiger',
    'Rabbit',
    'Dragon',
    'Snake',
    'Horse',
    'Goat',
    'Monkey',
    'Chicken',
    'Dog',
    'Pig',
    'Pigeon',
    'Hippo',
    'Lion',
    'Fox',
    'Rhino',
    'Eel',
    'Elephant',
    'Deer',
    'Dolphin',
    'Duck',
    'Seal',
    'Walrus',
    'Octopus',
    'Squid',
    'Salmon',
    'Worm',
    'Snail',
    'Shrimp',
    'Fish',
    'Whale',
    'Orca',
    'Bird',
    'Parrot',
    'Seagull',
    'Eagle',
    'Pelican',
    'Frog',
    'Toad',
    'Newt',
    'Dino',
    'Donkey',
    'Slug',
    'Ape',
    'Chimp',
    'Crab',
    'Lobster',
    'Bee',
    'Beetle',
    'Ant',
    'Hornet',
    'Butterfly',
    'Fly',
    'Moth',
    'Mosquito',
    'Kangaroo',
    'Giraffe',
    'Zebra',
    'Wolf',
  ];

  static const List<String> ADJECTIVES = [
    'Red',
    'Orange',
    'Yellow',
    'Green',
    'Blue',
    'Magenta',
    'Purple',
    'Black',
    'White',
    'Gray',
    'Happy',
    'Sad',
    'Angry',
    'Calm',
    'Crazy',
    'Furry',
    'Scaly',
    'Prickly',
    'Smooth',
    'Bald',
    'Big',
    'Small',
    'Long',
    'Short',
    'Fat',
    'Skinny',
    'Heavy',
    'Light',
    'Slow',
    'Fast',
    'Smelly',
    'Tasty',
    'Clean',
    'Dirty',
    'Ugly',
    'Pretty',
    'Scary',
    'Lovely',
    'Friendly',
    'Hot',
    'Cold',
    'Warm',
    'Cool',
    'Strange',
    'Young',
    'Old',
    'Strong',
    'Weak',
    'Tall',
    'Lonely'
  ];

  static String genNewName(Uint8List? addressByteIPv4) {
    late final int animalIdx;
    late final int adjIdx;
    if (addressByteIPv4 == null) {
      var rng = new Random();
      animalIdx = rng.nextInt(ANIMALS.length);
      adjIdx = rng.nextInt(ADJECTIVES.length);
    } else {
      int lastByte = addressByteIPv4.last;
      animalIdx = lastByte >> 4;
      adjIdx = lastByte & 0x0F;
    }
    return ADJECTIVES[adjIdx] + ' ' + ANIMALS[animalIdx];
  }
}
