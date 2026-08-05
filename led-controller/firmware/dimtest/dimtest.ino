// WIDS LED wall — droop diagnostic. Holds the whole strip WHITE at very low
// brightness (low current) so voltage droop at the tail disappears. If the last
// LEDs go clean white here but were red at full brightness => power droop, inject
// 5V at the tail. If they STAY red even this dim => data / wrong-LED-type fault.
#include <Adafruit_NeoPixel.h>
#define PIN 6
#define N   28
Adafruit_NeoPixel strip(N, PIN, NEO_GRBW + NEO_KHZ800);

void fillAll(uint32_t c){ for(int i=0;i<N;i++) strip.setPixelColor(i,c); strip.show(); }

void setup(){
  strip.begin();
  strip.setBrightness(12);      // ~5% -> tiny current, minimal droop
  fillAll(strip.Color(0,0,0,255));   // dim white (W die)
}
void loop(){
  fillAll(strip.Color(0,0,0,255)); delay(2500);  // dim white, held
  strip.clear(); strip.show();     delay(400);    // brief off so you see refresh
}
