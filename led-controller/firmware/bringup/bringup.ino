// WIDS LED wall — bring-up / smoke test.
// 28x SK6812 RGBW on data pin D6. Validates wiring, LED count, data direction,
// the LGT8F328 clone's WS2812 timing, and the RGB + white-die color order.
//
// Build for the LGT-Nano at 16 MHz (internal 32 MHz / div 2):
//   fqbn lgt8fx:avr:328:clock_source=internal,clock_div=2
#include <Adafruit_NeoPixel.h>

#define PIN 6
#define N   28
Adafruit_NeoPixel strip(N, PIN, NEO_GRBW + NEO_KHZ800);

void fillAll(uint32_t c) { for (int i = 0; i < N; i++) strip.setPixelColor(i, c); strip.show(); }

void setup() {
  strip.begin();
  strip.setBrightness(60);   // gentle on the supply during bring-up
  strip.clear();
  strip.show();
}

void loop() {
  // 1) WALK: light each LED alone (white), #0 first -> confirms count, order,
  //    and data direction. Watch which physical LED lights first.
  for (int i = 0; i < N; i++) {
    strip.clear();
    strip.setPixelColor(i, strip.Color(0, 0, 0, 255));  // white die only
    strip.show();
    delay(180);
  }
  // 2) COLOR TEST: whole strip R, G, B, then W (white die) -> confirms color
  //    order is correct (SK6812 = GRBW). If red shows green etc., order is off.
  fillAll(strip.Color(255, 0, 0, 0)); delay(800);   // red
  fillAll(strip.Color(0, 255, 0, 0)); delay(800);   // green
  fillAll(strip.Color(0, 0, 255, 0)); delay(800);   // blue
  fillAll(strip.Color(0, 0, 0, 255)); delay(800);   // white (dedicated W die)
  strip.clear(); strip.show(); delay(400);
}
