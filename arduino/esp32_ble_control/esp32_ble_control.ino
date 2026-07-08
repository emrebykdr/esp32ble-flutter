#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Flutter tarafı (ble_service.dart) servis/karakteristik UUID'i sabitlemiyor,
// ilk write özellikli karakteristiği komut, ilk notify özellikliyi sensör olarak kullanıyor.
// Yine de sabit UUID kullanmak taramada/keşifte daha güvenilir.
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define COMMAND_CHAR_UUID   "beb5483e-36e1-4688-b7f5-ea07361b26a8" // write, LED/röle komutu
#define SENSOR_CHAR_UUID    "0000ff01-0000-1000-8000-00805f9b34fb" // notify, mesafe (cm)

// Pinler donanıma göre değiştirilebilir
#define PIN_RED_LED   15
#define PIN_GREEN_LED 4
#define PIN_BLUE_LED  2
#define PIN_RELAY     5
#define PIN_TRIG      18
#define PIN_ECHO      19

// Flutter tarafındaki komut tablosuyla birebir eşleşmeli (ble_service.dart)
#define CMD_RED_LED_OFF   0x10
#define CMD_RED_LED_ON    0x11
#define CMD_GREEN_LED_OFF 0x20
#define CMD_GREEN_LED_ON  0x21
#define CMD_BLUE_LED_OFF  0x30
#define CMD_BLUE_LED_ON   0x31
#define CMD_RELAY_OFF     0x40
#define CMD_RELAY_ON      0x41

BLEServer* pServer = nullptr;
BLECharacteristic* pSensorChar = nullptr;
bool deviceConnected = false;
unsigned long lastSensorSend = 0;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    deviceConnected = true;
  }
  void onDisconnect(BLEServer* server) override {
    deviceConnected = false;
    server->startAdvertising(); // bağlantı kopunca tekrar keşfedilebilir olsun
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    if (c->getLength() == 0) return;
    uint8_t cmd = c->getData()[0];

    switch (cmd) {
      case CMD_RED_LED_ON:    digitalWrite(PIN_RED_LED, HIGH); break;
      case CMD_RED_LED_OFF:   digitalWrite(PIN_RED_LED, LOW);  break;
      case CMD_GREEN_LED_ON:  digitalWrite(PIN_GREEN_LED, HIGH); break;
      case CMD_GREEN_LED_OFF: digitalWrite(PIN_GREEN_LED, LOW);  break;
      case CMD_BLUE_LED_ON:   digitalWrite(PIN_BLUE_LED, HIGH); break;
      case CMD_BLUE_LED_OFF:  digitalWrite(PIN_BLUE_LED, LOW);  break;
      case CMD_RELAY_ON:      digitalWrite(PIN_RELAY, HIGH); break;
      case CMD_RELAY_OFF:     digitalWrite(PIN_RELAY, LOW);  break;
      default: break;
    }
  }
};

long readDistanceCm() {
  digitalWrite(PIN_TRIG, LOW);
  delayMicroseconds(2);
  digitalWrite(PIN_TRIG, HIGH);
  delayMicroseconds(10);
  digitalWrite(PIN_TRIG, LOW);

  long duration = pulseIn(PIN_ECHO, HIGH, 30000); // 30ms timeout, ~5m menzil
  if (duration == 0) return -1; // ping yankısız döndüyse
  return duration / 58; // us -> cm
}

void setup() {
  Serial.begin(115200);

  pinMode(PIN_RED_LED, OUTPUT);
  pinMode(PIN_GREEN_LED, OUTPUT);
  pinMode(PIN_BLUE_LED, OUTPUT);
  pinMode(PIN_RELAY, OUTPUT);
  pinMode(PIN_TRIG, OUTPUT);
  pinMode(PIN_ECHO, INPUT);

  BLEDevice::init("ESP32-BLE");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  BLECharacteristic* pCommandChar = pService->createCharacteristic(
    COMMAND_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCommandChar->setCallbacks(new CommandCallbacks());

  pSensorChar = pService->createCharacteristic(
    SENSOR_CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pSensorChar->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->start();
}

void loop() {
  // Flutter tarafı mesafeyi string olarak parse ediyor ("23" gibi), byte değil
  if (deviceConnected && millis() - lastSensorSend > 500) {
    long distance = readDistanceCm();
    if (distance >= 0) {
      String payload = String(distance);
      pSensorChar->setValue(payload.c_str());
      pSensorChar->notify();
    }
    lastSensorSend = millis();
  }
}
