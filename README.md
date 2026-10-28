# nesla.mama - Erlang Load Balancer

একটি সম্পূর্ণ এবং কনকারেন্ট (Concurrent) **Load Balancer** যা Erlang/OTP এর শক্তিশালী **Actor Model** এবং `gen_tcp` মডিউল ব্যবহার করে তৈরি করা হয়েছে।

---

## 🚀 বৈশিষ্ট্য (Key Features)

1. **Round-Robin অ্যালগরিদম**: ইনকামিং রিকোয়েস্টগুলোকে পর্যায়ক্রমে কনফিগার করা ব্যাকএন্ড সার্ভারগুলোর মধ্যে বণ্টন করে।
2. **অ্যাসিনক্রোনাস ও হাই কনকারেন্সি**: প্রতিটি ক্লায়েন্ট কানেকশনের জন্য Erlang এর লাইটওয়েট প্রসেস (Actor) তৈরি হয়। হাজার হাজার কানেকশন একসাথে হ্যান্ডেল করতে সক্ষম।
3. **দ্বিমুখী TCP রিলে (Bi-directional Proxy)**: ক্লায়েন্ট এবং ব্যাকএন্ডের মধ্যে রিয়েলটাইম প্যাকেট আদান-প্রদান।
4. **ফল্ট টলারেন্স ও রিট্রাই**: কোনো ব্যাকএন্ড সাময়িকভাবে ডাউন থাকলে এটি স্বয়ংক্রিয়ভাবে পরবর্তী সক্রিয় ব্যাকএন্ডে রিকোয়েস্ট পাঠিয়ে দেয়।
5. **টেস্টিং ব্যাকএন্ড অন্তর্ভুক্ত**: তাৎক্ষণিক পরীক্ষার জন্য ৩টি ডামি ব্যাকএন্ড সার্ভার স্ক্রিপ্ট দেওয়া হয়েছে (Port: 9001, 9002, 9003)।

---

## 📂 ফাইল স্ট্রাকচার

```
erlang_load_balancer/
├── src/
│   ├── load_balancer.erl    # মূল লোড ব্যালেন্সার লজিক ও প্রক্সি হ্যান্ডলার
│   ├── backend_server.erl   # টেস্টের জন্য ৩টি ডামি HTTP সার্ভার
│   └── demo.erl             # এক ক্লিকে ডেমো রান করার মডিউল
└── README.md                # প্রজেক্ট গাইড
```

---

## 🛠️ Erlang ইন্সটলেশন (যদি ইন্সটল না থাকে)

যদি আপনার কম্পিউটারে Erlang ইনস্টল না থাকে:
- **Windows**: [Erlang Official Download](https://www.erlang.org/patches/otp-26.2.2) অথবা PowerShell-এ:
  ```powershell
  winget install Erlang.Erlang
  ```
- **Linux (Ubuntu/Debian)**:
  ```bash
  sudo apt-get install erlang
  ```
- **macOS**:
  ```bash
  brew install erlang
  ```

---

## 🏃 কিভাবে চালাবেন (How to Run)

### ধাপ ১: প্রজেক্ট ডিরেক্টরিতে যান
```powershell
cd src
```

### ধাপ ২: Erlang শেল চালু করুন
```powershell
erl
```

### ধাপ ৩: কোড কম্পাইল করুন
Erlang শেলের ভেতরে লিখুন:
```erlang
c(load_balancer).
c(backend_server).
c(demo).
```

### ধাপ ৪: ব্যাকএন্ড ও লোড ব্যালেন্সার একসাথে চালু করুন
```erlang
demo:run().
```
*(অথবা আলাদা আলাদা চালু করতে চাইলে)*:
```erlang
backend_server:start_all().  % পোর্ট 9001, 9002, 9003 চালু করবে
load_balancer:start().       % পোর্ট 8080-এ লোড ব্যালেন্সার চালু করবে
```

---

## 🧪 টেস্ট করুন (Testing the Load Balancer)

অন্য একটি টার্মিনাল বা কমান্ড প্রম্পটে গিয়ে বারবার `curl` কমান্ড চালান:
```powershell
curl http://localhost:8080
curl http://localhost:8080
curl http://localhost:8080
curl http://localhost:8080
```

অথবা ব্রাউজারে `http://localhost:8080` খুলে রিফ্রেশ (Refresh) করুন।

### আউটপুট দেখতে পাবেন:
```text
Response from Backend Server on Port: 9001
Response from Backend Server on Port: 9002
Response from Backend Server on Port: 9003
Response from Backend Server on Port: 9001
```
প্রতিটি রিকোয়েস্ট Round-Robin নিয়মে একেকটি ব্যাকএন্ডে ডিস্ট্রিবিউট হচ্ছে!
