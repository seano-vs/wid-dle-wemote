// WIDS LED wall firmware — dumb renderer for 28x SK6812 RGBW on D6.
// The host bridge owns all mapping (channel/signature -> LED index) and sends
// simple line commands over USB serial @115200:
//   F <i> <r> <g> <b> <w> <ms>   flare LED i to RGBW, fade to idle over <ms>
//   A <i> <level>                idle/ambient white glow for LED i (0-255)
//   C                            clear all (ambient off, flares cancelled)
// Each LED renders as: ambient white glow + a decaying colored flare on top.
#include <Adafruit_NeoPixel.h>
#define PIN 6
#define N   28
Adafruit_NeoPixel strip(N, PIN, NEO_GRBW + NEO_KHZ800);

struct Led { uint8_t amb, r, g, b, w; unsigned long fstart; unsigned int fdur; };
Led led[N];
char buf[64]; uint8_t blen = 0;

void render() {
  unsigned long now = millis();
  for (int i = 0; i < N; i++) {
    uint8_t k = 0;                                   // flare intensity 255->0
    unsigned long e = now - led[i].fstart;
    if (led[i].fdur && e < led[i].fdur)
      k = 255 - (uint8_t)(e * 255UL / led[i].fdur);
    uint8_t r = (uint16_t)led[i].r * k / 255;
    uint8_t g = (uint16_t)led[i].g * k / 255;
    uint8_t b = (uint16_t)led[i].b * k / 255;
    uint16_t w = led[i].amb + (uint16_t)led[i].w * k / 255;
    if (w > 255) w = 255;
    strip.setPixelColor(i, r, g, b, (uint8_t)w);
  }
  strip.show();
}

void handle(char* s) {
  char* t = strtok(s, " ");
  if (!t) return;
  if (t[0] == 'C') { for (int i = 0; i < N; i++) { led[i].amb = 0; led[i].fdur = 0; } return; }
  if (t[0] == 'A') {
    int i = atoi(strtok(NULL, " ")); char* l = strtok(NULL, " ");
    if (l && i >= 0 && i < N) led[i].amb = constrain(atoi(l), 0, 255);
    return;
  }
  if (t[0] == 'F') {
    int i = atoi(strtok(NULL, " "));
    char *r = strtok(NULL, " "), *g = strtok(NULL, " "), *b = strtok(NULL, " ");
    char *w = strtok(NULL, " "), *d = strtok(NULL, " ");
    if (r && g && b && w && d && i >= 0 && i < N) {
      led[i].r = atoi(r); led[i].g = atoi(g); led[i].b = atoi(b); led[i].w = atoi(w);
      led[i].fstart = millis(); led[i].fdur = max(atoi(d), 1);
    }
    return;
  }
}

void setup() {
  Serial.begin(115200);
  strip.begin(); strip.setBrightness(180); strip.clear(); strip.show();
}

void loop() {
  // Drain serial every iteration (loop runs fast) so a burst can't overflow
  // the 64-byte RX buffer.
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') { if (blen) { buf[blen] = 0; handle(buf); blen = 0; } }
    else if (blen < sizeof(buf) - 1) buf[blen++] = c;
  }
  // Render at ~60 fps, then emit a '>' ready-prompt. The refresh disables
  // interrupts for ~1ms (NeoPixel requirement) and would drop any serial byte
  // arriving in that window; the host waits for '>' and only sends in the safe
  // gap right after, so no command is ever lost.
  static unsigned long last = 0;
  if (millis() - last >= 16) { last = millis(); render(); Serial.write('>'); }
}
