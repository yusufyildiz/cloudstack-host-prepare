# 🚀 CloudStack & Linstor KVM Network Automator

Bu depo (repository), **Apache CloudStack** ve **Linstor SDS** (Software Defined Storage) mimarisi için KVM hostlarının ağ yapılandırmasını otomatize eden Bash scriptlerini içerir.

Manuel konfigürasyon hatalarını ortadan kaldırmak, **Storage** ve **Management** trafiğini izole etmek ve **Jumbo Frame (MTU 9000)** performans ayarlarını standartlaştırmak için tasarlanmıştır.

## 🌟 Özellikler

* **🔍 Otomatik Keşif (Auto-Discovery):** Sunucu üzerindeki mevcut IP adreslerini, fiziksel ethernet portlarını ve bond yapılarını otomatik tespit eder.
* **🛡️ Güvenli Kurulum (Failback/Rollback):** Ağ yapılandırması sonrası Gateway erişimini test eder. Eğer bağlantı başarısız olursa, sunucuya erişimi kaybetmemeniz için değişiklikleri geri alır ve SSH için acil durum arayüzü oluşturur.
* **⚡ Performans Odaklı Topoloji:** * **Storage Ağı:** MTU 9000 (Jumbo Frames) ve Access Port mantığıyla yapılandırılır (Linstor/DRBD için).
    * **Management/Public/Guest Ağı:** MTU 1500 ve VLAN Tagging (Trunk) mantığıyla yapılandırılır.
* **📄 Configuration as Code:** Her sunucu için taşınabilir ve düzenlenebilir bir `server.conf` dosyası üretir.

## 🗺️ Ağ Topolojisi

Scriptler aşağıdaki ağ mimarisini uygular:

```text
       [ PHYSICAL SWITCH ]
      /                   \
  [VLAN 40 (Access)]    [TRUNK (Tagged)]
  (MTU 9000)            (MTU 1500)
      |                      |
+-----------+          +-----------+
|  bond0    |          |  bond1    |
+-----------+          +-----------+
      |                      |
      v                      v
 [cloudbr0]             [cloudbr1]  <---> [cloudbr100]
 (Storage IP)           (Mgmt IP)         (Public Traffic)
      |                      |
   LINSTOR              CloudStack
 Replication              Agent
