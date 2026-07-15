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

// Flutter tarafındaki komut tablosuyla birebir eşleşmeli (ble_service.dart).
// Metin tabanlı komutlar; okunabilirlik ve test kolaylığı için byte kodlar yerine tercih edildi.
#define CMD_RED_LED_ON    "RED_ON"
#define CMD_RED_LED_OFF   "RED_OFF"
#define CMD_GREEN_LED_ON  "GREEN_ON"
#define CMD_GREEN_LED_OFF "GREEN_OFF"
#define CMD_BLUE_LED_ON   "BLUE_ON"
#define CMD_BLUE_LED_OFF  "BLUE_OFF"
#define CMD_RELAY_ON      "RELAY_ON"
#define CMD_RELAY_OFF     "RELAY_OFF"

// Sensör ölçüm periyodu (ms)
#define SENSOR_PERIOD_MS  500

BLEServer* pServer = nullptr;
BLECharacteristic* pSensorChar = nullptr;

// Çekirdekler arası paylaşılan durum bayrakları
volatile bool deviceConnected = false;
volatile bool needAdvertise = false;

// Core 1 (sensör) -> Core 0 (BLE notify) veri kuyruğu
QueueHandle_t sensorQueue = nullptr;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    deviceConnected = true;
  }
  void onDisconnect(BLEServer* server) override {
    deviceConnected = false;
    // Advertising'i callback içinde hemen başlatmak yerine flag ile
    // notifyTask'a devrediyoruz; stack henüz hazır değilken çağrılmasını önler.
    needAdvertise = true;
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    if (c->getLength() == 0) return;

    // Ham byte'ları metin komutuna çevir (örn. "RED_ON")
    String cmd;
    uint8_t* data = c->getData();
    size_t len = c->getLength();
    cmd.reserve(len);
    for (size_t i = 0; i < len; i++) cmd += (char)data[i];

    // Callback içinde sadece hızlı GPIO işlemleri yapılıyor,
    // uzun süren iş burada YAPILMAMALI (BLE stack'i bloklar).
    if (cmd == CMD_RED_LED_ON)        digitalWrite(PIN_RED_LED, HIGH);
    else if (cmd == CMD_RED_LED_OFF)  digitalWrite(PIN_RED_LED, LOW);
    else if (cmd == CMD_GREEN_LED_ON) digitalWrite(PIN_GREEN_LED, HIGH);
    else if (cmd == CMD_GREEN_LED_OFF) digitalWrite(PIN_GREEN_LED, LOW);
    else if (cmd == CMD_BLUE_LED_ON)  digitalWrite(PIN_BLUE_LED, HIGH);
    else if (cmd == CMD_BLUE_LED_OFF) digitalWrite(PIN_BLUE_LED, LOW);
    else if (cmd == CMD_RELAY_ON)     digitalWrite(PIN_RELAY, HIGH);
    else if (cmd == CMD_RELAY_OFF)    digitalWrite(PIN_RELAY, LOW);
  }
};

long readDistanceCm() {
  digitalWrite(PIN_TRIG, LOW);
  delayMicroseconds(2);
  digitalWrite(PIN_TRIG, HIGH);
  delayMicroseconds(10);
  digitalWrite(PIN_TRIG, LOW);

  long duration = pulseIn(PIN_ECHO, HIGH, 30000); // 30ms timeout, ~5m menzil
  Serial.print("RAW duration(us)="); Serial.println(duration); // TEŞHİS İÇİN GEÇİCİ
  if (duration == 0) return -1; // yankı gelmedi
  return duration / 58; // us -> cm
}

// ---------------------------------------------------------------------------
// Core 1: Sensör ölçüm task'ı
// pulseIn'in 30ms'ye kadar süren blocking beklemesi bu çekirdekte izole kalır,
// BLE stack (Core 0) hiç etkilenmez.
// ---------------------------------------------------------------------------
void sensorTask(void* param) {
  for (;;) {
    long d = readDistanceCm();
    // Başarısız ölçüm (-1) de gönderiliyor; aksi halde characteristic son
    // başarılı değerde donup kalır ve web'deki polling bunu "güncel veri"
    // sanır (okuma teknik olarak başarılı olur, içeriği eski kalır).
    // Kuyruk doluysa bekleme (0 tick), eski ölçüm kaybolabilir; sorun değil.
    xQueueSend(sensorQueue, &d, 0);
    vTaskDelay(pdMS_TO_TICKS(SENSOR_PERIOD_MS));
  }
}

// ---------------------------------------------------------------------------
// Core 0: BLE notify task'ı
// BLE stack ile aynı çekirdekte çalışır; kuyruktan gelen ölçümü
// string olarak notify eder (Flutter tarafı "23" gibi string parse ediyor).
// Ayrıca kopan bağlantı sonrası advertising'i yeniden başlatır.
// ---------------------------------------------------------------------------
void notifyTask(void* param) {
  long d;
  char buf[8];
  for (;;) {
    // 100ms timeout: veri gelmese de advertising flag'ini kontrol edebilelim
    if (xQueueReceive(sensorQueue, &d, pdMS_TO_TICKS(100)) == pdTRUE) {
      if (deviceConnected) {
        snprintf(buf, sizeof(buf), "%ld", d);
        pSensorChar->setValue((uint8_t*)buf, strlen(buf));
        pSensorChar->notify();
      }
    }

    if (needAdvertise) {
      needAdvertise = false;
      vTaskDelay(pdMS_TO_TICKS(300)); // stack'in toparlanması için kısa bekleme
      BLEDevice::startAdvertising();
    }
  }
}

void setup() {
  Serial.begin(115200);

  pinMode(PIN_RED_LED, OUTPUT);
  pinMode(PIN_GREEN_LED, OUTPUT);
  pinMode(PIN_BLUE_LED, OUTPUT);
  pinMode(PIN_RELAY, OUTPUT);
  pinMode(PIN_TRIG, OUTPUT);
  pinMode(PIN_ECHO, INPUT);

  // Not: Röle modülü low-trigger ise LOW = açık demektir;
  // donanımda test edip gerekirse komut mantığını ters çevir.
  digitalWrite(PIN_RELAY, HIGH);

  BLEDevice::init("ESP32-BLE");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  BLECharacteristic* pCommandChar = pService->createCharacteristic(
    COMMAND_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCommandChar->setCallbacks(new CommandCallbacks());

  // READ eklendi: web tarafı startNotifications() yerine periyodik readValue()
  // ile polling yapıyor (Windows Chrome'daki startNotifications() bug'ı yüzünden).
  pSensorChar = pService->createCharacteristic(
    SENSOR_CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  pSensorChar->addDescriptor(new BLE2902());
  pSensorChar->setValue("0");

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->start();

  // FreeRTOS task'ları: sensör Core 1'e, notify Core 0'a sabitlenir
  sensorQueue = xQueueCreate(5, sizeof(long));
  xTaskCreatePinnedToCore(sensorTask, "sensor", 2048, NULL, 1, NULL, 1); // Core 1
  xTaskCreatePinnedToCore(notifyTask, "notify", 4096, NULL, 2, NULL, 0); // Core 0

  Serial.println("BLE server hazir, advertising basladi.");
}

void loop() {
  // Tüm iş task'larda; loop'u uyutuyoruz.
  vTaskDelay(portMAX_DELAY);
}
