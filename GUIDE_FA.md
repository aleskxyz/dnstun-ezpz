توی این راهنما نحوه استفاده از اسکریپت DNSTUN-EZPZ رو توضیح میدم.

چی داریم:

3 تا سرور با IP های زیر

    60.70.80.90 (id=1)
    60.70.80.91 (id=2)
    60.70.80.92 (id=3)
با اون id های داخل پرانتز بعدا کار داریم.

2 تا دامنه:

    demo1.com
    demo2.com

توضیح: برای استفاده از این اسکریپت داشتن یک سرور و یک دامنه هم کافیه. شما با یک سرور و یک دامنه میتونید ترکیبهای مختلف dnstt و slipstream رو با ssh و socks راه بندازید.


چی میخوایم:

روی هر دامنه دو تا سرویبس میخوایم.
روی دامنه demo1.com میخوایم dnstt رو با ssh و slipstream  رو با socks ایجاد کنیم و روی دامنه دوم میخوایم dnstt رو با socks و slipstream رو با ssh ایجاد کنیم.


چیکار باید بکنیم:

اسکریپت حتماً باید با root اجرا شود. وارد سرور اول میشیم و دستور زیر رو اجرا میکنیم:
```
sudo -i
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.2.0/dnstun-ezpz.sh")
```
چندتا سوال از ما پرسیده میشه که به این صورت جواب میدیم:
```
Enter this server's ID (1-255): 1
Enter prefix for server domain names [s]: s
Enter number of servers [3]: 3
Enter username (for SSH and SOCKS) [vpnuser]: vpnuser
Enter password (for SSH and SOCKS): P@ssword
Enter number of domains [1]: 4
Enter domain name #1: ns1.demo1.com
Enter transport for ns1.demo1.com (dnstt/slipstream): dnstt
Enter protocol for ns1.demo1.com (ssh/socks): ssh
Enter domain name #2: ns2.demo1.com
Enter transport for ns2.demo1.com (dnstt/slipstream): slipstream
Enter protocol for ns2.demo1.com (ssh/socks): socks
Enter domain name #3: ns1.demo2.com
Enter transport for ns1.demo2.com (dnstt/slipstream): dnstt
Enter protocol for ns1.demo2.com (ssh/socks): socks
Enter domain name #4: ns2.demo2.com
Enter transport for ns2.demo2.com (dnstt/slipstream): slipstream
Enter protocol for ns2.demo2.com (ssh/socks): ssh
Enter DNSTT private key (hex, 64 chars). Leave empty to keep current or generate new key:
```

سوال اول: شناسه این سرور (۱ تا ۲۵۵). سرور اول = ۱، سرور دوم = ۲ و غیره. این عدد باید با ساب‌دامین سرور یکی باشه (مثلاً s1 یعنی id=1). بعداً موقع ساختن A رکوردها باید هر سرور را با همین ID و IP درست به s1، s2، … وصل کنید وگرنه Slipstream کار نمی‌کند (پایین‌تر توضیح داده شده).

سوال دوم: پیشوند برای اسم سرورها (پیش‌فرض s). بین ۱ تا ۶۳ کاراکتر: حروف انگلیسی، عدد و خط‌تیره مجاز است؛ خط‌تیره فقط در وسط باشد (نه در ابتدا و نه در انتها). بهتر است پیشوند را تا حد ممکن کوتاه نگه دارید (مثلاً `s`) چون در نام هر ساب‌دامین سرور (مثل s1.demo1.com) استفاده می‌شود. من حرف s رو انتخاب کردم.

سوال سوم: تعداد سرورهای کلاستر (پیش‌فرض ۳). اینجا ۳ رو وارد می‌کنیم.

سوال چهارم: نام کاربری برای تونل SSH و پروکسی SOCKS (پیش‌فرض vpnuser).

سوال پنجم: رمز عبور برای همون کاربر (برای SSH و SOCKS).

سوال ششم: تعداد دامنه‌های جلویی (front domain). اینجا ۴ تا داریم: ns1.demo1.com، ns2.demo1.com، ns1.demo2.com، ns2.demo2.com — یعنی روی هر دامنهٔ اصلی (demo1 و demo2) دو تا سرویس (یکی dnstt و یکی slipstream).

برای هر دامنه سه سوال پرسیده میشه:
- **نام دامنه** (مثلاً ns1.demo1.com)
- **ترنسپورت (transport)**: dnstt یا slipstream — یعنی نوع تونل DNS.
- **پروتکل (protocol)**: ssh یا socks — یعنی بعد از تونل، کلاینت به SSH وصل بشه یا به پروکسی SOCKS.

این سه تا رو برای هر چهار دامنه وارد می‌کنیم. در آخر اگر حداقل یک دامنه dnstt داشته باشیم، کلید خصوصی DNSTT رو می‌پرسه:

- **خالی Enter بزنید** تا اسکریپت خودش یک کلید جدید بسازه، یا اگر دارید reconfigure می‌کنید همان کلید فعلی بمونه.
- **کلید قبلی رو paste کنید** اگر می‌خواهید از یک کانفیگ dnstt قدیمی مهاجرت کنید تا کلاینت‌ها بدون تعویض کلید عمومی کار کنند.
- برای **ساختن دستی یک کلید جدید** (مثلاً برای عوض کردن کلید فعلی) می‌توانید این دستور را بزنید و مقدار `privkey` را وقتی اسکریپت پرسید وارد کنید:
```
docker run --rm ghcr.io/aleskxyz/dnstt-server:1.1.0 -gen-key
```
در نهایت اسکریپت کار کانفیگ رو شروع میکنه. اول توی warp برای این سرور یه اکانت ایجاد میکنه و بعد فایلهای مورد نیاز رو میسازه و سرویس رو بالا میاره. قسمت پایین خروجی این رو نشونمون میده:
```
Generating transport key (DNSTT)...
Detected SSH port: 22
Registering WARP device (accepting ToS) via wgcf...
2026/03/06 10:43:50 Using config file: /data/wgcf-account.toml
2026/03/06 10:43:52 Printing account details:
2026/03/06 10:43:52 Successfully created Cloudflare Warp account
=============================================
Account
=============================================
Id   : 63c2fd7a-baa9-4d22-84da-bf43af39922b
Account type : free
Created  : 2026-03-06T10:43:50.868744Z
Updated  : 2026-03-06T10:43:50.868744Z
Premium data : 0 B
Quota  : 0 B
Role   : child
=============================================
Devices
=============================================
Id  : 3ef151e3-b389-4871-bc0a-03d1ec499b4e (current)
Type  : Android
Model  : PC
Name  : 1B9F56
Active : true
Created : 2026-03-06T10:43:50.541618Z
Activated : 2026-03-06T10:43:50.541618Z
Role  : parent
WARN[0000] Warning: No resource found to remove for project "dnstun-ezpz".
[+] up 7/7
✔ Container dnstun-ezpz-dnstt-1-1  Created
✔ Container dnstun-ezpz-slipstream-1-1  Created
✔ Container dnstun-ezpz-dnstt-2-1  Created
✔ Container dnstun-ezpz-slipstream-2-1  Created
✔ Container dnstun-ezpz-dns-lb-1  Created
✔ Container dnstun-ezpz-singbox-1  Created
✔ Container dnstun-ezpz-route-setup-1  Created
```

پایین‌تر کانفیگ کلاینت برای هر instance چاپ میشه (دامنه، ترنسپورت، پروتکل، کاربر/رمز؛ برای dnstt کلید عمومی هم هست). همچنین برای هر instance یک **SlipNet URI** و **کد QR** نمایش داده میشه که میتونید مستقیماً توی اپ [SlipNet](https://github.com/AnonVector/SlipNet) اسکن یا paste کنید:
```
==== CLIENT CONFIG ====

--- Instance 1 ---
domain: ns1.demo1.com
transport: dnstt
protocol: ssh
username: vpnuser
password: P@ssword
public_key: 665e2fade9ee6a38bff5afdc0a9a03f231a812930f9f45125be8d3c90832e20c

SlipNet URI:
slipnet://MTd8ZG5zdHRfc3NofGRuc3R0LXNza...

█████████████████████████
████ ▄▄▄▄▄ █ ... █████
  (کد QR قابل اسکن)
█████████████████████████
---

--- Instance 2 ---
domain: ns2.demo1.com
transport: slipstream
protocol: socks
username: vpnuser
password: P@ssword

SlipNet URI:
slipnet://MTd8c3N8c2xpcHN0cmVhb...

(کد QR)
---

--- Instance 3 ---
domain: ns1.demo2.com
transport: dnstt
protocol: socks
username: vpnuser
password: P@ssword
public_key: 665e2fade9ee6a38bff5afdc0a9a03f231a812930f9f45125be8d3c90832e20c

SlipNet URI:
slipnet://MTd8ZG5zdHR8ZG5zdHQtc29...

(کد QR)
---

--- Instance 4 ---
domain: ns2.demo2.com
transport: slipstream
protocol: ssh
username: vpnuser
password: P@ssword

SlipNet URI:
slipnet://MTd8c2xpcHN0cmVhbV9zc2...

(کد QR)
---
```

پایینتر از اون راهنمای کانفیگ DNS رو بهتون نشون داده:
```
==== DNS RECORDS TO CREATE ====

1) A records (zone: demo1.com) — point each server hostname to that server's public IP (server id in brackets):

    s1.demo1.com   A   <server-1-public-ip>   [server id: 1]
    s2.demo1.com   A   <server-2-public-ip>   [server id: 2]
    s3.demo1.com   A   <server-3-public-ip>   [server id: 3]

2) NS records — for each domain, delegate to the servers (in the parent zone of each domain):

    For ns1.demo1.com:
    ns1.demo1.com   NS   s1.demo1.com.
    ns1.demo1.com   NS   s2.demo1.com.
    ns1.demo1.com   NS   s3.demo1.com.

    For ns2.demo1.com:
    ns2.demo1.com   NS   s1.demo1.com.
    ns2.demo1.com   NS   s2.demo1.com.
    ns2.demo1.com   NS   s3.demo1.com.

    For ns1.demo2.com:
    ns1.demo2.com   NS   s1.demo1.com.
    ns1.demo2.com   NS   s2.demo1.com.
    ns1.demo2.com   NS   s3.demo1.com.

    For ns2.demo2.com:
    ns2.demo2.com   NS   s1.demo1.com.
    ns2.demo2.com   NS   s2.demo1.com.
    ns2.demo2.com   NS   s3.demo1.com.
```
توجه: نام zone از اولین دامنه گرفته میشه؛ پس Aها همیشه زیر همون دامنه هستن، مثلاً demo1.com. برای دامنهٔ دوم مثل demo2.com فقط NS رکورد می‌سازید و به همون s1/s2/s3.demo1.com اشاره می‌کنید.


یعنی باید اول وارد پنل مدیریت دامنه demo1.com بشید و سه تا A رکورد بسازید به نام های s1 s2 s3 به سمت آی پی سه تا سروری که دارید.

یعنی:
```
s1.demo1.com   A   60.70.80.90
s2.demo1.com   A   60.70.80.91
s3.demo1.com   A   60.70.80.92
```
**مهم (به‌ویژه برای Slipstream):** رابطهٔ **شناسهٔ سرور (Server ID)**، **ساب‌دامین A رکورد** و **IP هر سرور** باید دقیقاً درست باشه: سروری که موقع اجرای اسکریپت یا join شناسهٔ ۱ دادید باید همون سروری باشه که IPاش پشت `s1.دامنه` قرار گرفته، سرور ۲ پشت `s2.دامنه` و همین‌طور تا آخر. اگر این تطابق رعایت نشه (مثلاً IP سرور ۲ رو برای s1 بذارید)، **Slipstream** درست کار نمی‌کنه؛ dnstt ممکنه کماکان کار کنه ولی برای کلاستر درست حتماً Aها رو با ID و IP واقعی هر سرور هماهنگ کنید.

بعد باید 6 تا ns رکورد بسازید. سه تا واسه ns1 به سمت هر کدوم از اون A رکوردهایی که ساختید و سه تا برای ns2

بعد باید وارد پنل مدیریت دامنه demo2.com بشید و فقط 6 تا ns رکورد بسازید به سمت A رکورد هایی که توی دامنه demo1.com ساختید. اینجا ساختن A رکورد لازم نیست.

قسمت آخر خروجی یه چنین چیزی میبینید:


    ==== JOIN COMMAND (run on other servers to join this cluster) ====

    Run on other servers to join:

    bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.2.0/dnstun-ezpz.sh") "<BASE64_JOIN_CONFIG>"


خروجی اسکریپت در آخر یک خط «Join command» با یک رشتهٔ base64 نشون میده. اون خط رو کامل کپی کنید. روی سرور دوم و سوم با root همان دستور رو اجرا کنید؛ اسکریپت از شما فقط «این سرور ID چنده؟» (۲ و ۳) رو می‌پرسه و بقیهٔ کانفیگ رو از همون رشته می‌گیره. بعد از join، کلاستر تکمیل میشه.

حالا می‌تونید با اسکن کد QR یا paste کردن SlipNet URI مستقیماً توی اپ SlipNet پروفایل رو وارد کنید. همچنین میتونید دامنه، ترنسپورت، پروتکل، کاربر/رمز و کلید عمومی رو به صورت دستی در کلاینت وارد کنید.

یه کم زمان میبره تا تنظیمات DNS ها اعمال بشه.

اگر بعد از ایجاد کانفیگ دوباره اسکریپت رو بدون آرگومان اجرا کنید، یک منو نشون داده میشه:

    bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.2.0/dnstun-ezpz.sh")
    Select action:
    1) Print current config
    2) Reconfigure cluster
    3) Start services
    4) Stop services
    5) Restart services
    6) Uninstall cluster
    Enter choice [1-6]:

با وارد کردن عدد هر گزینه آن عملیات اجرا میشه:

1. **نمایش کانفیگ فعلی** — همان خروجی دامنه/ترنسپورت/پروتکل، SlipNet URI و کد QR برای هر instance، رکوردهای DNS و دستور join.
2. **تنظیم مجدد کلاستر** — تغییر ID سرور، پیشوند، تعداد سرور، کاربر/رمز، دامنه‌ها، ترنسپورت و پروتکل. بعد از تغییر حتماً دستور join جدید رو در بقیه سرورها هم اجرا کنید.
3. **استارت سرویس‌ها**
4. **توقف سرویس‌ها**
5. **ریستارت سرویس‌ها**
6. **حذف کامل کلاستر** — حذف کانتینرها، اکانت WARP و کاربر تونل و پوشهٔ `/opt/dnstun-ezpz`.

حتماً در همهٔ سرورهای کلاستر از یک نسخهٔ واحد اسکریپت استفاده کنید (نسخه داخل لینک، مثلاً `v0.2.0`). برای آپدیت، نسخه رو در لینک عوض کنید، گزینهٔ ۲ (Reconfigure) رو بزنید و بعد دستور join جدید رو روی بقیه سرورها اجرا کنید. اگر چیزی در کانفیگ عوض نکنید، تنظیمات کلاینت همان‌طور می‌مونه.