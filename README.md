# 🛡️ DoorAuth
### *A Complete Multi-Device Door Authentication & Security System for CC:Tweaked*
#### Keypads • Door Controllers • Auth Server • Admin Remote • Door Fob • Lockdown • Audit Logs • Auto-Discovery

## 📌 Overview
DoorAuth is a fully modular, distributed, secure access-control system for CC:Tweaked. It uses a central server to manage:

- PIN validation  
- Per-user access codes  
- Shared JSON-based configuration  
- Door databases  
- Controller registration  
- Remote admin commands  
- Audit logging  
- Lockdown mode  
- Client heartbeat monitoring  
- Searchable and cloneable user management  
- Reusable card token issuance  

All clients (keypads, controllers, pocket apps) are stateless for maximum security and reliability.

## 🧠 System Architecture
DoorAuth consists of **five major components**:

### 1. Auth Server (Core Brain)
- Stores PINs and door configurations  
- Stores per-user codes and door entitlements  
- Verifies all PIN entry attempts  
- Sends open commands to controllers  
- Handles admin login (hashed PIN + session tokens)  
- Global Lockdown mode  
- Persistent audit logs  

### Startup Setup
- Each script shows a 3-second setup prompt on launch  
- Press any key during the countdown to edit values  
- Settings are saved to `doorauth_config.json`  
- Heartbeat monitoring  

### 2. Door Controllers (Per-Door Redstone Units)
- Register to the auth server  
- Listen for open commands  
- Pulse redstone  
- Auto-reconnect  
- Heartbeat response  

### 3. Keypad Computers (Touchscreen Entry Terminals)
- Touchscreen numeric keypad  
- Masked PIN entry  
- Server-side verification  
- Clean feedback  
- Auto-reconnect  

### 4. Pocket Admin Remote (Secure Admin Console)
- Secure login  
- Session tokens  
- Add/remove PINs  
- Add/remove users  
- Enable/disable doors per user  
- View user door access  
- Clear user code, clear all doors, clone access  
- Search users  
- Door management  
- Lockdown mode  
- Remote door open  
- Audit log viewer  

### 5. Lockdown Alarm
- Polls the server for lockdown state
- Drives a configurable redstone output when lockdown is enabled
- Turns the signal off again when lockdown is cleared

### 6. Door Fob (Player Access Device)
- Auto-discovers doors  
- Simple door selection  
- Enter code  
- Server verifies  
- Lightweight & portable  

## ⚙️ Hardware Support
- Regular computers  
- Advanced computers  
- Computers with monitors  
- Wired/Wireless modems  
- Pocket computers  

## 📦 Included Programs
auth_server.lua  
door_controller.lua  
keypad_door.lua  
admin_remote.lua  
lockdown_alarm.lua  
door_fob.lua  
doorauth_api_example.lua  

## 🚀 Installation
1. Install scripts on devices  
2. Configure ADMIN_PIN_HASH in auth_server.lua  
3. Attach modems and wiring  
4. Reboot all devices  

## 🧪 Testing Procedure
1. Start auth server  
2. Start door controllers  
3. Start keypads  
4. Add PIN via admin remote  
5. Test keypad  
6. Test fob  
7. Lockdown test  
8. Check audit logs  

## 🔌 API Example
- Load `doorauth_api_example.lua` with `os.loadAPI("doorauth_api_example")`  
- Use `doorauth_api_example.login(pin)` to create an admin session  
- Call `doorauth_api_example.listUsers(session)` or `doorauth_api_example.addUser(session, name, code)` from your own programs  
- The helper auto-renews the admin session if it expires  

## 🔐 Security Model
- Server holds all PINs  
- Hashed admin PIN  
- Session tokens  
- Lockdown override  
- Audit logging  

## 🤝 Contributing
PRs welcome!

## 📄 License
MIT License recommended.
