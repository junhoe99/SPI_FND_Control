`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/11/07 14:57:40
// Design Name: 
// Module Name: Master
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module Master(
    // Global Signals
    input logic clk,
    input logic reset,
    // Button Interface
    input logic run_stop,
    input logic clear,
    // SPI Interface
    output logic o_SCLK,
    output logic o_MOSI,
    output logic o_SS_N, 
    input logic i_MISO     // 이번 프로젝트에서는 FND Controll이 목적이다보니, 사용할일이 없음.

    );

    // Internal Signals
    logic [7:0] tx_data;
    logic start;
    logic ss_n;
    logic tx_ready;
    logic done;

    SPI_Master U_SPI_Master (
        .clk(clk),
        .reset(reset),
        .start(start),
        .tx_data(tx_data),
        .tx_ready(tx_ready),
        .done(done),
        .SCLK(o_SCLK),
        .MOSI(o_MOSI),
        .MISO(i_MISO)
    );

    // SS_N은 UpCounter에서 직접 제어
    assign o_SS_N = ss_n;

    UpCounter U_UpCounter (
        .clk(clk),
        .reset(reset),
        .run_stop(run_stop),
        .clear(clear),
        .tx_ready(tx_ready),
        .done(done),
        .tx_data(tx_data),
        .start(start),
        .ss_n(ss_n)
    );
endmodule





module UpCounter(
    // Global Signals
    input logic clk,
    input logic reset,
    // Input Signals (Buttons)
    input logic run_stop,    // 카운트 시작/정지 토글
    input logic clear,       // 카운터 초기화
    // Input Signals (From SPI Master)
    input logic tx_ready,    // SPI Master가 전송 준비 완료 (IDLE 상태)
    input logic done,        // SPI Master가 전송 완료 (8bit 전송 끝)
    // Output Signals (To SPI Master)
    output logic [7:0] tx_data,   // 전송할 8bit 데이터 (0~255)
    output logic start,           // SPI 전송 시작 신호
    output logic ss_n             // Slave Select 신호 (Active Low)
    );

    // ========================================
    // 목표 동작:
    // 1. run_stop 버튼: 카운트 시작/정지 토글
    // 2. clear 버튼: 카운터 0으로 초기화
    // 3. 8비트 카운터 (0~255 반복)
    // 4. 일정 주기로 카운트 증가 후 SPI 전송
    // 5. tx_ready 확인 후 start 신호 발생 (충돌 방지)
    // 6. done 신호로 전송 완료 확인
    // ========================================

    typedef enum logic [3:0] {
        IDLE,
        RUN,
        STOP,
        CLEAR_SEND,        // Clear 시 즉시 0 전송
        WAIT_TX_READY,
        SEND_HIGH_BYTE,
        WAIT_HIGH_DONE,
        SEND_LOW_BYTE,
        WAIT_LOW_DONE
    } state_t;

    state_t c_state, n_state;

    // Registers
    logic [13:0] counter_reg, counter_next;      // 14비트 카운터 (0~9999)
    logic [31:0] clk_count_reg, clk_count_next;  // 주기 카운트용
    logic start_reg, start_next;                  // SPI 시작 신호
    logic ss_n_reg, ss_n_next;                   // Slave Select 신호
    logic return_to_idle_reg, return_to_idle_next; // 전송 완료 후 IDLE로 돌아갈지 여부

    // ========================================
    // State Register
    // ========================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            c_state <= IDLE;
            counter_reg <= 14'd0;
            clk_count_reg <= 32'd0;
            start_reg <= 1'b0;
            ss_n_reg <= 1'b1;  // SS_N = High (비활성)
            return_to_idle_reg <= 1'b0;
        end else begin
            c_state <= n_state;
            counter_reg <= counter_next;
            clk_count_reg <= clk_count_next;
            start_reg <= start_next;
            ss_n_reg <= ss_n_next;
            return_to_idle_reg <= return_to_idle_next;
        end
    end

    // ========================================
    // Next State Logic + Output Logic
    // ========================================
    always_comb begin
        // 기본값 설정 (Latch 방지)
        n_state = c_state;
        counter_next = counter_reg;
        clk_count_next = clk_count_reg;
        start_next = 1'b0;
        ss_n_next = 1'b1;  // 기본값: SS_N = High (비활성)
        return_to_idle_next = return_to_idle_reg;
        
        case(c_state)
            IDLE: begin
                // 초기 상태: 카운터 정지
                counter_next = 14'd0;
                clk_count_next = 32'd0;
                start_next = 1'b0;
                
                if (clear) begin
                    n_state = CLEAR_SEND;  // Clear 시 즉시 0 전송
                end else if (run_stop) begin
                    n_state = RUN;
                end else begin
                    n_state = IDLE;
                end
            end

            RUN: begin
                // 카운팅 중: 일정 주기마다 증가
                if (clear) begin
                    // Clear 버튼: 즉시 초기화 후 0 전송
                    counter_next = 14'd0;
                    clk_count_next = 32'd0;
                    n_state = CLEAR_SEND;
                end else if (run_stop) begin
                    // Run/Stop 버튼: 현재 값 유지하고 정지
                    clk_count_next = 32'd0;
                    n_state = STOP;
                end else begin
                    // 일정 주기 체크 (예: 0.01초마다 증가 = 1,000,000 클럭)
                    if (clk_count_reg >= 32'd9_999_999) begin
                        clk_count_next = 32'd0;
                        // 14비트 카운터: 0~9999 순환
                        if (counter_reg >= 14'd9999) begin
                            counter_next = 14'd0;
                        end else begin
                            counter_next = counter_reg + 1'b1;
                        end
                        n_state = WAIT_TX_READY;  // SPI 전송 준비
                    end else begin
                        clk_count_next = clk_count_reg + 1'b1;
                        n_state = RUN;
                    end
                end
            end

            STOP: begin
                // 정지 상태: 카운터 값 유지
                counter_next = counter_reg;
                clk_count_next = 32'd0;
                start_next = 1'b0;
                
                if (clear) begin
                    counter_next = 14'd0;
                    n_state = CLEAR_SEND;  // Clear 시 즉시 0 전송
                end else if (run_stop) begin
                    n_state = RUN;
                end else begin
                    n_state = STOP;
                end
            end

            CLEAR_SEND: begin
                // *** Clear 버튼 시 즉시 0 전송 ***
                // counter_reg는 이미 0으로 설정됨
                counter_next = 14'd0;
                clk_count_next = 32'd0;
                start_next = 1'b0;
                ss_n_next = 1'b1;  // 아직 비활성
                return_to_idle_next = 1'b1;  // 전송 완료 후 IDLE로 복귀
                
                // SPI Master가 준비되면 즉시 0 전송
                if (tx_ready) begin
                    n_state = SEND_HIGH_BYTE;  // 0 값 전송 시작
                end else begin
                    n_state = CLEAR_SEND;  // 준비될 때까지 대기
                end
            end

            WAIT_TX_READY: begin
                // *** SPI Master가 준비될 때까지 대기 ***
                // tx_ready=1이면 SPI Master가 IDLE 상태 (전송 가능)
                start_next = 1'b0;
                ss_n_next = 1'b1;  // 아직 비활성
                return_to_idle_next = 1'b0;  // 정상 카운팅이므로 RUN으로 복귀
                
                if (tx_ready) begin
                    n_state = SEND_HIGH_BYTE;  // 상위 바이트 전송 시작
                end else begin
                    n_state = WAIT_TX_READY;  // 계속 대기
                end
            end

            SEND_HIGH_BYTE: begin
                // *** 상위 바이트 전송 시작 ***
                start_next = 1'b1;  // start 펄스 (1클럭)
                ss_n_next = 1'b0;   // SS_N = Low (Slave 활성화)
                n_state = WAIT_HIGH_DONE;
            end

            WAIT_HIGH_DONE: begin
                // *** 상위 바이트 전송 완료 대기 ***
                start_next = 1'b0;  // start 신호 해제
                ss_n_next = 1'b0;   // SS_N = Low 유지 (아직 전송 중)
                
                if (done) begin
                    n_state = SEND_LOW_BYTE;  // 하위 바이트 전송으로 이동
                end else begin
                    n_state = WAIT_HIGH_DONE;  // 전송 완료까지 대기
                end
            end

            SEND_LOW_BYTE: begin
                // *** 하위 바이트 전송 시작 ***
                start_next = 1'b1;  // start 펄스 (1클럭)
                ss_n_next = 1'b0;   // SS_N = Low 유지
                n_state = WAIT_LOW_DONE;
            end

            WAIT_LOW_DONE: begin
                // *** 하위 바이트 전송 완료 대기 ***
                start_next = 1'b0;  // start 신호 해제
                ss_n_next = 1'b0;   // SS_N = Low 유지
                
                if (done) begin
                    ss_n_next = 1'b1;  // 모든 전송 완료 시 SS_N = High (비활성화)
                    // 전송 완료 후 돌아갈 상태 결정
                    if (return_to_idle_reg) begin
                        n_state = IDLE;  // Clear에서 온 경우 IDLE로
                    end else begin
                        n_state = RUN;   // 정상 카운팅에서 온 경우 RUN으로
                    end
                end else begin
                    n_state = WAIT_LOW_DONE;  // 전송 완료까지 대기
                end
            end

            default: begin
                n_state = IDLE;
                counter_next = 14'd0;
                clk_count_next = 32'd0;
                start_next = 1'b0;
                ss_n_next = 1'b1;  // 기본값: 비활성
                return_to_idle_next = 1'b0;
            end
        endcase
    end

    // ========================================
    // 출력 할당
    // ========================================
    // 2-byte 전송: 상위 바이트와 하위 바이트 분할
    // counter_reg: 0~9999 → High:상위바이트(counter/100), Low:하위바이트(counter%100)
    logic [7:0] high_byte, low_byte;
    assign high_byte = counter_reg / 100;    // 상위: 0~99 (100의 자리)
    assign low_byte = counter_reg % 100;     // 하위: 0~99 (1의 자리)
    
    // 현재 상태에 따라 전송할 바이트 선택
    assign tx_data = (c_state == SEND_HIGH_BYTE || c_state == WAIT_HIGH_DONE) ? high_byte : low_byte;
    assign start = start_reg;
    assign ss_n = ss_n_reg;             // SS_N 신호 출력

endmodule


module SPI_Master (
    // Global Signals
    input logic clk,
    input logic reset,
    // Internal Signals
    input logic start,
    input logic [7:0] tx_data,
    output logic [7:0] rx_data,
    output logic tx_ready,
    output logic done,
    // External SPI Signals
    output logic SCLK,
    output logic MOSI,
    input logic MISO
    // SS_N은 UpCounter에서 직접 제어
);


    // 현재 설계에서는, SCLK의 반주기를 CPO(SCLK=0), 나머지 반 주기를 CP1(SCLK=1)로 정의하고,
    // 각 State에서 MOSI, MISO 신호를 처리하는 방식으로 구현.
    typedef enum {
        IDLE,
        CP0,
        CP1
    } state_t;

    state_t c_state, n_state;

    logic [7:0] tx_data_reg, tx_data_next;          // To prevent Latch
    logic [7:0] rx_data_reg, rx_data_next;          // To prevent Latch

    logic [5:0] sclk_count_reg, sclk_count_next;    // To prevent Latch
    logic [2:0] bit_count_reg, bit_count_next;        // To prevent Latch


    // State Register
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            c_state <= IDLE;
            tx_data_reg <= 8'b0;
            rx_data_reg <= 8'b0;
            sclk_count_reg <= 6'b0;
            bit_count_reg <= 3'b0;
        end else begin
            c_state <= n_state;
            tx_data_reg <= tx_data_next;
            rx_data_reg <= rx_data_next;
            sclk_count_reg <= sclk_count_next;
            bit_count_reg <= bit_count_next;
        end
    end


    // Next State Logic(Combinational) + Output Logic(Combinational)
    always_comb begin
        n_state = c_state;  // 기본값 설정
        tx_data_next = tx_data_reg;  // 기본값 설정
        rx_data_next = rx_data_reg;  // 기본값 설정
        sclk_count_next = sclk_count_reg;  // 기본값 설정
        bit_count_next = bit_count_reg;  // 기본값 설정
        tx_ready = 1'b0;  // 기본값 설정
        done = 1'b0;  // 기본값 설정
        SCLK = 1'b0;  // CPOL = 0기준, 기본값 설정
        case (c_state)
            IDLE: begin
                    done = 1'b0;          // Output Port 신호이므로, register화 하지 않아도 됨.
                    tx_ready = 1'b1;      // Output Port 신호이므로, register화 하지 않아도 됨.
                    sclk_count_next = 0;
                    bit_count_next = 0;
                if (start) begin
                    n_state = CP0;
                    tx_data_next = tx_data;  //TX data latching
                end else begin
                    n_state = IDLE;
                end
            end
            CP0: begin
                SCLK = 0; // Output Port 신호이므로, register화 하지 않아도 됨.
                if (sclk_count_reg == 49) begin    // Rising Edge
                    rx_data_next = {rx_data_reg[6:0], MISO};  // MSB first 수신
                    sclk_count_next = 0;
                    n_state = CP1;
                end else begin
                    sclk_count_next = sclk_count_reg + 1;
                    n_state = CP0;
                end
            end
            CP1: begin
                SCLK = 1; // Output Port 신호이므로, register화 하지 않아도 됨.
                if (sclk_count_reg == 49) begin
                    sclk_count_next = 0;
                    if (bit_count_reg == 7) begin   // Falling Edge
                        bit_count_next = 0;
                        done = 1;
                        n_state = IDLE;
                    end else begin
                        bit_count_next = bit_count_reg + 1;
                        tx_data_next = {tx_data_reg[6:0], 1'b0};  // MSB first 전송
                        n_state = CP0;
                    end
                end else begin
                    sclk_count_next = sclk_count_reg + 1;
                    n_state = CP1;
                end
            end
        endcase
    end

    // 왜, tx_data, bit_count, sclk_count같은 신호들을 레지스터화 했는가?
    // => Latch 방지 목적.
    // => Combinational logic에서 신호의 다음 상태를 결정할 때,
    //    해당 신호들이 레지스터화 되어 있지 않으면, 신호의 이전 상태를 유지하기 위해 Latch가 생성될 수 있음.
    //    이는 예상치 못한 동작을 초래할 수 있음.
    // 하지만 만약 해당 신호가 Module의 output 포트라면, 레지스터화 하지 않아도 됨.
    // => Module의 output 포트는 기본적으로 Combinational logic에서 값을 할당받기 때문에,
    //    Latch가 생성될 위험이 없음. 
    //
    // 즉, 모듈의 internal signal들이 combinational logic속에서 그 값이 바뀌게 된다면
    // 해당 signal들은 레지스터화 해야함. (LATCH 방지 목적)
    // 반면에, 모듈의 output 포트들은 레지스터화 하지 않아도 됨.

    assign MOSI = tx_data_reg[7];  // MSB first 전송
    assign rx_data = rx_data_reg;  // 최종 수신 데이터
endmodule
