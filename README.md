# 🔌 SPI Master-Slave FND Controller

## 🔍 Project Overview

> 이 프로젝트는 **SystemVerilog HDL 기반 SPI통신 시스템**입니다. 단일 FPGA 내에서 Master와 Slave 모듈을 구현하여, Master가 0~9999까지 카운팅한 값을 SPI 통신으로 전송하면 Slave가 이를 수신하여 4-digit FND(7-Segment Display)에 표시합니다.

## 🎯 Key Features

### 🔧 System Features
- **Dual Role Implementation**: 하나의 FPGA에서 Master/Slave 동시 구현
- **Full SPI Protocol**: CPOL=0, CPHA=0 모드의 완전한 SPI 통신
- **CDC (Clock Domain Crossing)**: 3단 Synchronizer를 통한 Metastability 방지
- **14-bit Counter**: 0~9999 범위의 Up Counter 구현
- **Multi-byte Transmission**: 2-byte 분할 전송 방식 (High/Low Byte)
- **Hardware Debouncing**: 버튼 입력의 채터링 제거

### 📡 SPI Communication
- **Clock Frequency**: SCLK = 1MHz (100MHz 시스템 클럭에서 분주)
- **Data Width**: 8-bit 전송 단위
- **Transmission Mode**: MSB First
- **SPI Mode**: Mode 0 (CPOL=0, CPHA=0)
- **Slave Select**: Active Low (SS_N)

### 🖥️ Display System
- **FND Type**: 4-digit 7-Segment Common Anode
- **Display Range**: 0000 ~ 9999
- **Refresh Rate**: 1kHz (Dynamic Scanning)
- **Encoding**: BCD to 7-Segment Decoder

### 🎛️ Control Interface
- **Run/Stop Button**: 카운터 시작/정지 토글
- **Clear Button**: 카운터 0으로 리셋
- **Count Period**: 0.01초마다 1씩 증가 (10ms)


## 🏗️ System Architecture

### 📊 Design Concept
<img width="3440" height="1152" alt="image" src="https://github.com/user-attachments/assets/32cec99e-312c-4d23-b3cf-d1aa41f2373b" />


### 📊 Block Diagram
<img width="5472" height="2356" alt="image" src="https://github.com/user-attachments/assets/b992db17-b8fc-4072-9025-93b60e7521b3" />




### 🗂️ Project Structure

```
📁 SPI_Master_Slave_FND.srcs/
│
├── 📂 sources_1/new/
│   ├── 🔝 SPI_TOP.sv                    # 최상위 통합 모듈
│   │   ├── Master.sv                    # Master 컨트롤러
│   │   │   ├── UpCounter                # 카운터 & 상태 머신
│   │   │   └── SPI_Master               # SPI 송신 엔진
│   │   ├── Slave.sv                     # Slave 컨트롤러
│   │   │   ├── SPI_Slave                # SPI 수신 엔진 (3-stage Synchronizer)
│   │   │   ├── ControlUnit              # 2-byte 병합 로직
│   │   │   └── fnd_controller           # FND 구동 시스템
│   │   │       ├── digit_spliter        # 10진수 → BCD 변환
│   │   │       ├── bcd_decoder          # BCD → 7-segment 변환
│   │   │       ├── mux_4x1              # 4개 digit 선택
│   │   │       ├── mux_2x4              # FND common 선택
│   │   │       ├── counter_4            # 2-bit digit selector
│   │   │       └── clk_div              # 1kHz clock 생성
│   │   └── btn_debounce                 # 버튼 디바운싱
│   │
└── 📂 constrs_1/new/
    └── xdc.xdc                          # Basys3 핀 제약 파일
```

## 🔬 Technical Deep Dive

### 1️⃣ Master Side: UpCounter & SPI Transmission

#### 📈 State Machine (UpCounter)
```
IDLE → RUN → WAIT_TX_READY → SEND_HIGH_BYTE → WAIT_HIGH_DONE 
       ↑                                              ↓
       └──────────────────────────────────────────────┘
                              ↓
       ┌──────────────────────────────────────────────┐
       ↓                                              ↑
SEND_LOW_BYTE → WAIT_LOW_DONE → (RUN or IDLE)
```

**핵심 동작:**
- **10ms 주기 카운팅**: `clk_count_reg`로 10,000,000 클럭 카운트
- **2-Byte Encoding**: 
  - High Byte = `counter / 100` (0~99)
  - Low Byte = `counter % 100` (0~99)
- **Sequential Transmission**: High → Low 순서로 전송

#### ⚡ SPI Master Protocol
```systemverilog
// CPOL=0, CPHA=0: Rising edge에서 데이터 샘플링
State: IDLE → CP0 → CP1 → ... (8 cycles) → IDLE

CP0 (SCLK=0): 50 clocks (0.5μs)
CP1 (SCLK=1): 50 clocks (0.5μs)
Total: 1MHz SCLK (1μs period)
```

### 2️⃣ Slave Side: CDC & Data Reception

#### 🔒 Clock Domain Crossing 해결

**문제 상황:**
- Master SCLK (1MHz, 비동기) ↔ Slave clk (100MHz, 시스템)
- Phase 불일치 → Setup/Hold time 위반 → **Metastability 발생**

**해결책: 3단 Synchronizer**
```systemverilog
// i_SCLK 동기화
always_ff @(posedge clk) begin
    sclk_sync <= {sclk_sync[1:0], i_SCLK};
    // [0]: 메타스태빌 가능 (10ns 해소 시간)
    // [1]: 안정화 중 (누적 20ns)
    // [2]: 완전 안정 (누적 30ns, MTBF > 10^15년)
end

// Edge Detection
assign sclk_rising_edge = (sclk_sync[2:1] == 2'b01);
```

**타이밍 분석:**
```
i_SCLK (비동기): _______________/‾‾‾‾‾‾‾‾‾‾‾‾‾
                            42ns ↑ (예시)

clk (100MHz):    ↑____↑____↑____↑____↑____↑____↑
                 0    10   20   30   40   50   60ns

sclk_sync[0]:    ________________?????__/‾‾‾‾‾‾
                                50ns (메타스태빌 가능)

sclk_sync[1]:    ________________________???___/‾
                                        60ns (안정화)

sclk_sync[2]:    ________________________________/‾
                                            70ns (완전 안정)

sclk_rising_edge:________________________________/‾\
                                            70ns (1클럭 펄스)
```

**i_MOSI 샘플링이 안전한 이유:**
- `sclk_rising_edge`는 이미 3단 동기화 완료 (2~3 클럭 지연)
- 이 지연 동안 `i_MOSI`는 Master의 SCLK에 의해 이미 안정된 상태
- 따라서 `i_MOSI`는 별도 동기화 불필요

#### 🔀 2-Byte Merge (ControlUnit)
```systemverilog
// State: WAIT_HIGH_BYTE → WAIT_LOW_BYTE → UPDATE_DISPLAY

// 수신 완료 시:
fnd_data = (high_byte × 100) + low_byte  // 0~9999 복원
```

### 3️⃣ Display System: FND Controller

#### 🎨 Dynamic Scanning (1kHz)
```
Time:     0ms    1ms    2ms    3ms    4ms    5ms...
fnd_com:  0001   0010   0100   1000   0001   0010...
Digit:    D0     D1     D2     D3     D0     D1...
Value:    units  tens  hundreds thousands...

POV(Persistence of Vision)로 모든 자릿수가 동시에 켜진 것처럼 보임
```

## 🔧 Configuration

### ⚙️ System Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| **System Clock** | 100MHz | Basys3 보드 내장 클럭 |
| **SCLK Frequency** | 1MHz | SPI 통신 클럭 (50 system clocks/half) |
| **Counter Range** | 0~9999 | 14-bit counter |
| **Count Period** | 10ms | 카운트 증가 주기 |
| **FND Refresh** | 1kHz | Dynamic scanning 주파수 |
| **Debounce Time** | ~4μs | 버튼 안정화 시간 |

### 🔌 Pin Assignment (Basys3 Board)

#### Inputs
- **clk (W5)**: 100MHz 시스템 클럭
- **reset (U18)**: 중앙 버튼 (BTNC)
- **run_stop (T18)**: 위쪽 버튼 (BTNU)
- **clear (W19)**: 왼쪽 버튼 (BTNL)

#### Outputs (FND)
- **fnd_data[6:0]**: 7-segment 데이터 (W7, W6, U8, V8, U5, V5, U7)
- **fnd_com[3:0]**: Common 선택 (U2, U4, V4, W4)

#### SPI Interface
- **JB (Master Output)**: 
  - o_SCLK (A14), o_MOSI (A16), o_SS_N (B15), i_MISO (B16)
- **JC (Slave Input)**: 
  - i_SCLK (K17), i_MOSI (M18), i_SS_N (N17), o_MISO (P18)

**연결 방법:** JB와 JC를 점퍼선으로 1:1 연결

## 🎮 How to Use

### 🚀 Basic Operation

1. **초기화**: `reset` 버튼 누름 → FND에 "0000" 표시
2. **카운트 시작**: `run_stop` 버튼 누름 → 10ms마다 1씩 증가
3. **카운트 정지**: `run_stop` 버튼 다시 누름 → 현재 값 유지
4. **초기화**: `clear` 버튼 누름 → 즉시 0으로 리셋 및 전송

### 🔄 Operation Flow

```
Power On → Reset → IDLE (0000)
                     ↓
         [Run/Stop] → RUN (카운팅 시작)
                     ↓
            0001, 0002, 0003, ... , 9999, 0000, ...
                     ↓
         [Run/Stop] → STOP (현재 값 유지)
                     ↓
          [Clear]   → CLEAR_SEND → IDLE (0000)
```

### 📊 Timing Example

```
시간      동작                          FND 표시
0.00s  → 카운트 시작                    0000
0.01s  → +1 & SPI 전송                 0001
0.02s  → +1 & SPI 전송                 0002
...
1.00s  → +1 & SPI 전송                 0100
...
99.99s → +1 & SPI 전송                 9999
100.00s→ +1 & SPI 전송                 0000 (Wrap)
```

## 🧪 Testing & Verification

### ✅ Test Cases

#### 1. Basic Functionality
- [x] 카운터 0~9999 정상 동작
- [x] Run/Stop 토글 기능
- [x] Clear 버튼 즉시 리셋
- [x] FND 표시 정확도

#### 2. SPI Communication
- [x] SCLK 1MHz 주파수 검증
- [x] 2-byte 분할 전송
- [x] MSB First 전송 순서
- [x] SS_N Active Low 동작

#### 3. CDC (Clock Domain Crossing)
- [x] 3단 Synchronizer 동작
- [x] Edge Detection 정확도
- [x] Metastability 없음 확인
- [x] 장시간 안정성 테스트

#### 4. Display System
- [x] 4-digit 동시 표시
- [x] 1kHz 리프레시 깜빡임 없음
- [x] BCD 디코딩 정확도

### 🔍 Debugging Tools

**ILA (Integrated Logic Analyzer) 권장 프로브 포인트:**
```
Master:
- counter_reg[13:0]
- tx_data[7:0]
- start, done
- c_state

Slave:
- sclk_sync[2:0]
- sclk_rising_edge
- rx_shift_reg[7:0]
- fnd_data[13:0]
```

## 🚨 Design Notes & Considerations

### ⚠️ Known Limitations

1. **Single Master/Slave**: 현재 1:1 통신만 지원
2. **No Error Detection**: CRC/Parity 검증 미구현
3. **Fixed Timing**: SCLK 주파수 하드코딩
4. **No FIFO**: 연속 데이터 버퍼링 없음

### 💡 Design Decisions

#### Why 2-Byte Transmission?
- **문제**: 8-bit SPI로 14-bit 데이터 전송 불가
- **해결**: `value/100`과 `value%100`로 분할 (각각 0~99 범위)
- **장점**: 간단한 인코딩/디코딩, 오버헤드 최소화

#### Why 3-Stage Synchronizer?
- **2-Stage**: MTBF ≈ 10^6~10^9년 (일반적 충분)
- **3-Stage**: MTBF ≈ 10^15년 이상 (고신뢰성 보장)
- **선택 이유**: 교육 목적 + 안전성 극대화

#### Why 1MHz SCLK?
- **Fast enough**: 8-bit × 2 = 16μs (10ms 주기 대비 충분)
- **Slow enough**: CDC 안정성 확보 (100MHz 대비 1/100)
- **Practical**: 대부분 SPI 디바이스 지원 범위

### 🔮 Future Enhancements

- [ ] **Multi-Slave Support**: SS_N 다중화로 여러 Slave 제어
- [ ] **Error Detection**: CRC-8 체크섬 추가
- [ ] **Configurable SCLK**: 파라미터화된 클럭 분주기
- [ ] **FIFO Buffer**: 연속 데이터 전송 지원
- [ ] **SPI Mode Select**: Mode 1/2/3 추가 지원
- [ ] **Interrupt Driven**: Polling 대신 Interrupt 방식

## 📈 Performance Specifications

| Metric | Value | Notes |
|--------|-------|-------|
| **System Clock** | 100MHz | Basys3 고정 |
| **SPI Throughput** | 1Mbps | 1MHz × 1-bit |
| **Byte Transfer Time** | 8μs | 8 bits × 1μs |
| **Full Counter Update** | ~16μs | 2 bytes × 8μs |
| **Counter Latency** | <1ms | 10ms 주기 내 |
| **FND Update Rate** | 1kHz | 깜빡임 없음 보장 |
| **Debounce Delay** | ~4μs | 100MHz / 100 × 4 |
| **Max Count Rate** | 100 counts/sec | 10ms period |

## 🛠️ Build & Deploy

### 📋 Requirements
- **FPGA Board**: Xilinx Basys3 (Artix-7)
- **Vivado**: 2018.2 이상
- **Cables**: JB-JC 점퍼선 4개 (SCLK, MOSI, SS_N, MISO)

### 🔨 Build Steps

1. **프로젝트 열기**
   ```bash
   Vivado → Open Project → SPI_Master_Slave_FND.xpr
   ```

2. **Synthesis & Implementation**
   ```
   Flow Navigator → Run Synthesis
                 → Run Implementation
                 → Generate Bitstream
   ```

3. **프로그래밍**
   ```
   Hardware Manager → Open Target → Auto Connect
                   → Program Device → Select .bit file
   ```

4. **하드웨어 연결**
   ```
   JB1 (SCLK) → JC1 점퍼선 연결
   JB2 (MOSI) → JC2 점퍼선 연결
   JB3 (SS_N) → JC3 점퍼선 연결
   JB4 (MISO) → JC4 점퍼선 연결 (현재 미사용)
   ```

### ⚡ Quick Test

```
1. BTNC (reset) 눌러서 초기화
2. FND가 "0000" 표시 확인
3. BTNU (run_stop) 눌러서 카운트 시작
4. 0.01초마다 증가하는지 확인
5. BTNL (clear) 눌러서 0으로 리셋 확인
```

## 📚 References & Resources

### 📖 Documentation
- [SPI Protocol Specification (Motorola)](https://www.analog.com/en/analog-dialogue/articles/introduction-to-spi-interface.html)
- [FPGA CDC Best Practices (Xilinx UG912)](https://www.xilinx.com/support/documentation/sw_manuals/xilinx2020_2/ug912-vivado-properties.pdf)
- [7-Segment Display Multiplexing](https://www.electronics-tutorials.ws/blog/7-segment-display-tutorial.html)

### 🔧 Related Concepts
- **Metastability**: Setup/Hold time 위반으로 인한 불안정 상태
- **MTBF (Mean Time Between Failures)**: 평균 고장 간격
- **POV (Persistence of Vision)**: 잔상 효과로 인한 연속 표시
- **Dynamic Scanning**: 시분할 멀티플렉싱 기법

### 🌐 Useful Links
- [SPI Tutorial - SparkFun](https://learn.sparkfun.com/tutorials/serial-peripheral-interface-spi)
- [CDC Techniques - FPGA4Fun](https://www.fpga4fun.com/CrossClockDomain.html)
- [Basys3 Reference Manual](https://digilent.com/reference/programmable-logic/basys-3/reference-manual)

---

## 👨‍💻 Author & License

**Project**: SPI Master-Slave FND Controller  
**Date**: November 2025  
**Purpose**: FPGA 통신 프로토콜 학습 및 CDC 기법 실습

---

## 📝 Changelog

### v1.0 (2025-11-07)
- ✅ 초기 프로젝트 생성
- ✅ Master/Slave 기본 구현
- ✅ 3-stage Synchronizer 적용
- ✅ 2-byte 분할 전송 방식
- ✅ Button debouncing 추가
- ✅ FND dynamic scanning 구현

---

**💡 Tip**: 이 프로젝트는 SPI 통신, CDC 기법, 상태 머신 설계를 학습하기에 최적화된 교육용 프로젝트입니다!
