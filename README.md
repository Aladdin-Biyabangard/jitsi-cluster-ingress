# jitsi-cluster

GCP-də Jitsi Meet cluster + multi-Jibri recording + Bunny Stream upload.

Canlı server (`meet.ingress.academy`) konfiqlərinə əsaslanır: 15 nəfərlik qruplar, 720p, simulcast, TURN, recording.

**Default (10 paralel recording, 5 Jibri / VM):**

```
meet-control   e2-standard-4     Nginx + Prosody + Jicofo + Coturn
meet-jvb       e2-standard-8     Video bridge
recorder-1..2  e2-standard-8     hər VM-də 5 Jibri → Bunny
```

`CONCURRENT_RECORDINGS=10` → deploy **2 recorder VM × 5 Jibri proses** seçir.  
1 VM ≠ 1 record — eyni hostda `jibri@1`…`jibri@5` işləyir; Jicofo brewery boş slotu seçir. Gələcəkdə `CONCURRENT_RECORDINGS` artır/azaltmaq kifayətdir.

---

## Tələblər

- `gcloud` + `gcloud auth login`
- GCP project + **billing aktiv**
- `.env` doldurulmuş

`./deploy.sh` avtomatik: Terraform, jq, API enable, App Engine (scheduler), SSH, VM-lər, multi-Jibri, DNS, scheduler.

---

## Start

```bash
git clone https://github.com/Aladdin-Biyabangard/jitsi-cluster-ingress.git 
cd jitsi-cluster-ingress
cp .env.example .env
nano .env          # doldurun
./deploy.sh
```

Deploy ~20–40 dəqiqə. Sonunda:

```
URL: https://meet.yourdomain.com
meet-control IP: x.x.x.x
```

DNS A record: `DOMAIN → meet-control IP` (Cloudflare token versəniz avtomatik).

---

## `.env`

| Dəyişən | Məcburi | İzah |
|---------|---------|------|
| `GCP_PROJECT_ID` | ✅ | GCP project |
| `DOMAIN` | ✅ | məs. `meet.example.com` |
| `ADMIN_EMAIL` | ✅ | Let's Encrypt |
| `BUNNY_LIBRARY_ID` | ✅ recording | Stream → Video library ID |
| `BUNNY_API_KEY` | ✅ recording | Stream → API Key (Read-only DEYİL) |
| `BUNNY_CDN_HOSTNAME` | optional | CDN hostname |
| `CONCURRENT_RECORDINGS` | | Default `10` (2×5 Jibri) |
| `CLOUDFLARE_*` | | DNS avtomatik |
| `SCHEDULE_*` | | Default: 03:30–06:05 UTC (= 07:30–10:05 Bakı) |

---

## Recording axını

```
Meeting → Start recording
    ↓
Jibri MP4 yazır (/srv/recordings/slot-N)
    ↓
Stop / meeting bitir
    ↓
finalize_recording.sh  (fayl settle gözləyir)
    ↓
bunny-upload.sh
    0) GET  portal /api/jitsi/room/{uuid}/upload-meta/  → teacher collectionId
    1) POST /library/{id}/videos  (+ collectionId)      → video GUID
    2) PUT  /library/{id}/videos/{guid}                 → MP4 binary
    ↓
HTTP 2xx  →  lokal MP4 + qovluq silinir
```

Ingress portal (`bunny_stream.py`) ilə eyni Bunny Stream API.
Hər müəllimin videosu öz Bunny collection-una düşür (`TeacherProfile.bunny_collection_id`).

Log: hər recorder-də `/var/log/jitsi/bunny-uploads.jsonl`

---

## Arxitektura

```
                    Internet
                       │
          ┌────────────┼────────────┐
          ▼                         ▼
   meet-control                 meet-jvb
   (HTTPS/XMPP/TURN)            (UDP 10000)
          │                         │
          └──────────┬──────────────┘
                     │ VPC internal
              ┌──────┴──────┐
              ▼             ▼
        recorder-1     recorder-2
        jibri@1…@5     jibri@1…@5
              │             │
              └──────┬──────┘
                     ▼
               Bunny Stream
```

```bash
CONCURRENT_RECORDINGS=10   # eyni anda max recording
# RECORDER_COUNT=2         # optional
# JIBRI_PER_VM=5           # optional
```

**IP qənaəti:** yalnız `meet-control` və `meet-jvb` statik xarici IP. Recorder-lər yalnız daxili IP (SSH: meet-control bastion).

---

## Schedule

`ENABLE_SCHEDULE=true` → Cloud Scheduler VM start/stop.

| Bakı | UTC (default) |
|------|---------------|
| 07:30 start | 03:30 |
| 10:05 stop | 06:05 |

```bash
GCP_PROJECT_ID=... GCP_ZONE=europe-west1-b ./scripts/schedule-all.sh start
GCP_PROJECT_ID=... GCP_ZONE=europe-west1-b ./scripts/schedule-all.sh stop
```

---

## Fayl strukturu

```
jitsi-cluster/
├── deploy.sh
├── destroy.sh
├── .env.example
├── config/
│   ├── meet-custom.js      # live 15-user + recording
│   ├── jvb-custom.conf
│   ├── jicofo-custom.conf
│   ├── prosody-muc.snippet
│   └── sysctl-jitsi.conf
├── scripts/
│   ├── setup-control.sh
│   ├── setup-jvb.sh
│   ├── setup-jibri.sh      # multi-slot Jibri
│   ├── bunny-upload.sh
│   ├── finalize_recording.sh
│   ├── schedule-all.sh
│   └── install-scheduler-jobs.sh
└── terraform/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

---

## Quota (yeni GCP hesabı)

| Limit | Default | Bu deploy |
|-------|---------|-----------|
| `CPUS_ALL_REGIONS` | 32 | 4+8+2×8 = **28** |
| `IN_USE_ADDRESSES` | 8 | **2** |

Daha çox paralel recording: `CONCURRENT_RECORDINGS` artırın və ya [Quota](https://console.cloud.google.com/iam-admin/quotas) artırın.

---

## Troubleshooting

| Problem | Həll |
|---------|------|
| `CPUS_ALL_REGIONS` exceeded | `RECORDER_COUNT` / `JIBRI_MACHINE_TYPE` azaldın və ya quota |
| Recording düyməsi yoxdur | `journalctl -u 'jibri@*' -n 50` |
| JVB qoşulmur | Prosody 5222 + `jitsi-allow-internal` |
| Bunny upload fail | `/var/log/jitsi/recording-finalize.log`, `bunny.env` |
| Recorder setup | `secrets/setup-recorder-*.log` |

Silmək:

```bash
./destroy.sh
```
