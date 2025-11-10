`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/11/07 15:00:51
// Design Name: 
// Module Name: Slave
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


module Slave(
    // Global Signals
    input logic clk,
    input logic reset,
    // SPI Interface (상대 FPGA의 Master로부터 들어오는 신호)
    input logic i_SCLK,
    input logic i_MOSI,
    input logic i_SS_N, 
    output logic o_MISO,
    // Fnd Interface
    output logic [6:0] fnd_data,
    output logic [3:0] fnd_com
    );

    // Internal Signals
    logic [7:0] w_rx_data;    // SPI Slave가 수신한 데이터
    logic w_done;              // SPI 수신 완료 신호
    logic [13:0] w_fnd_data;   // FND 표시용 14bit 데이터


    SPI_Slave U_SPI_Slave (
        .clk(clk),
        .reset(reset),
        .i_SCLK(i_SCLK),
        .i_MOSI(i_MOSI),
        .i_SS_N(i_SS_N),
        .o_MISO(o_MISO),
        .rx_data(w_rx_data),
        .done(w_done)
    );

    ControlUnit U_ControlUnit (
        .clk(clk),
        .reset(reset),
        .rx_data(w_rx_data),
        .done(w_done),
        .fnd_data(w_fnd_data)
    );

    fnd_controller U_Fnd_controller (
        .clk(clk),
        .rst(reset),
        .i_fnd_data(w_fnd_data),
        .o_fnd_data(fnd_data),
        .fnd_com(fnd_com)
    );

endmodule


module SPI_Slave(
    // Global Signals
    input logic clk,          // System clock (FPGA 내부 클럭 - 100MHz)
    input logic reset,
    // SPI Interface (외부 Master로부터 들어오는 신호들)
    input logic i_SCLK,       // Master로부터 받는 SPI Clock (느린 클럭, 예: 1MHz)
    input logic i_MOSI,       // Master로부터 받는 데이터 (Master Out Slave In)
    input logic i_SS_N,       // Slave Select (Active Low - 0일 때 활성화)
    output logic o_MISO,      // Master에게 보내는 데이터 (Master In Slave Out, 현재 미사용)
    // Control Unit Interface
    output logic [7:0] rx_data,  // 수신 완료된 8bit 데이터
    output logic done            // 수신 완료 신호 (1클럭 펄스)
    );

    // ========================================
    // Slave는 외부에서 들어오는 SCLK에 동기화되어야 함
    // 하지만 시스템 클럭(clk)으로 동작하면서 SCLK의 edge를 검출하는 방식 사용
    // ========================================
    
    // SCLK와 SS_N 동기화 레지스터 (Metastability 방지용)
    logic [2:0] sclk_sync;     // 3단계 동기화 (CDC - Clock Domain Crossing)
    logic [2:0] ss_n_sync;     // 3단계 동기화
    
    // Edge detection 신호
    logic sclk_rising_edge;    // SCLK의 0->1 변화 감지
    logic sclk_falling_edge;   // SCLK의 1->0 변화 감지
    logic ss_n_active;          // SS_N이 활성화(Low) 상태인지
    
    // Data registers
    logic [7:0] rx_shift_reg;   // 수신 데이터 시프트 레지스터 (비트별로 한칸씩 이동)
    logic [7:0] tx_shift_reg;   // 송신 데이터 시프트 레지스터 (MISO용, 현재 미사용)
    logic [2:0] bit_counter;     // 비트 카운터 (0~7까지 카운트)
    logic rx_done;              // 내부 수신 완료 플래그
    
    
    // ========================================
    // 1단계: SCLK와 SS_N 동기화 (Metastability 방지)
    // ========================================
    // 외부에서 들어오는 비동기 신호를 시스템 클럭에 동기화
    // 3단 플립플롭으로 동기화하여 안정적인 신호 생성
    // 일명, Synchronizer라고도 불림
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            sclk_sync <= 3'b000;
            ss_n_sync <= 3'b111;  // SS_N은 기본적으로 High (비활성)
        end else begin
            // 3비트 시프트 레지스터로 동기화
            sclk_sync <= {sclk_sync[1:0], i_SCLK};  // [2]가 가장 안정적인 신호
            ss_n_sync <= {ss_n_sync[1:0], i_SS_N};
        end
    end
    
    // Edge detection: 이전 값(bit[2])과 현재 값(bit[1])을 비교
    assign sclk_rising_edge = (sclk_sync[2:1] == 2'b01);   // 0->1 transition
    assign sclk_falling_edge = (sclk_sync[2:1] == 2'b10);  // 1->0 transition
    assign ss_n_active = ~ss_n_sync[2];  // Active Low이므로 반전 (0일 때 true)
    
    
    // ========================================
    // 2단계: SPI Slave 수신 로직 (CPOL=0, CPHA=0 기준)
    // ========================================
    // SPI 모드: CPOL=0 (Idle 상태에서 SCLK=0), CPHA=0 (첫 번째 edge에서 샘플링)
    // 동작:
    //   - SCLK Rising Edge (0->1): MOSI 데이터를 읽어서 shift register에 저장
    //   - SCLK Falling Edge (1->0): 다음 비트를 준비 (MISO 업데이트, 현재 미사용)
    //   - 8비트 수신 완료 시 done 신호 발생
    
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rx_shift_reg <= 8'h00;
            tx_shift_reg <= 8'h00;
            bit_counter <= 3'd0;
            rx_done <= 1'b0;
        end 
        else begin
            rx_done <= 1'b0;  // 기본적으로 done은 0 (1클럭 펄스를 위해)
            
            if (!ss_n_active) begin
                // SS_N이 High (비활성)이면 초기화
                // Slave가 선택되지 않은 상태
                bit_counter <= 3'd0;
                rx_shift_reg <= 8'h00;
                tx_shift_reg <= 8'h00;
            end 
            else begin
                // SS_N이 Low (활성)일 때만 SPI 통신 동작
                
                if (sclk_rising_edge) begin
                    // *** 중요: SCLK Rising Edge에서 MOSI 데이터 샘플링 ***
                    // MSB First 방식: 먼저 들어온 비트가 상위 비트
                    rx_shift_reg <= {rx_shift_reg[6:0], i_MOSI};  
                    bit_counter <= bit_counter + 1'b1;
                    
                    // 8비트 모두 수신 완료 (bit 7까지 받으면 다음 edge에서 카운터가 0이 됨)
                    if (bit_counter == 3'd7) begin
                        rx_done <= 1'b1;      // 수신 완료 신호 (1클럭 펄스)
                        bit_counter <= 3'd0;  // 다음 바이트를 위해 리셋
                    end
                end
                
                // Falling Edge에서는 MISO 준비 (현재 프로젝트에서는 사용 안함)
                // if (sclk_falling_edge) begin
                //     tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};  // 다음 비트 준비
                // end
            end
        end
    end
    
    
    // Output Logic
    assign rx_data = rx_shift_reg;  // 현재 수신된 데이터 (8비트 완료 시 유효)
    assign done = rx_done;           // 수신 완료 신호 (8비트 수신 완료 시 1클럭 동안 High)
    
    // MISO는 현재 프로젝트에서 사용하지 않음 (단방향 FND Control 목적)
    // 필요시 tx_shift_reg의 MSB를 출력하면 됨
    assign o_MISO = 1'b0;  // 또는 tx_shift_reg[7];
    
endmodule



// ========================================
// Control Unit: SPI로 받은 2개의 8bit 데이터를 조합하여 0~9999 표현
// ========================================
// 
// *** 핵심 아이디어: 2-Byte 조합 ***
// - Master는 0~9999 값을 2개의 8bit로 분할해서 전송
// - 인코딩 방식: high_byte = value/100, low_byte = value%100
// - 디코딩 방식: fnd_data = (high_byte × 100) + low_byte
// 
// 동작:
//   1. 첫 번째 done: rx_data → high_byte (상위: 0~99, 100의 자리)
//   2. 두 번째 done: rx_data → low_byte (하위: 0~99, 1의 자리)
//   3. fnd_data = high_byte × 100 + low_byte (0~9999)
//
module ControlUnit(
    input logic clk,
    input logic reset,
    input logic [7:0] rx_data,   // SPI로 수신한 8bit 데이터 (0~255)
    input logic done,             // SPI 수신 완료 신호 (1클럭 펄스)
    output logic [13:0] fnd_data  // FND 표시용 14bit 데이터 (0~9999)
);

    // State machine
    typedef enum logic [1:0] {
        WAIT_HIGH_BYTE,    // 첫 번째 바이트 (상위) 대기
        WAIT_LOW_BYTE,     // 두 번째 바이트 (하위) 대기
        UPDATE_DISPLAY     // 디스플레이 업데이트
    } state_t;

    state_t c_state, n_state;
    
    // Registers
    logic [7:0] high_byte_reg, high_byte_next;   // 상위 바이트 저장 (0~99)
    logic [13:0] fnd_data_reg, fnd_data_next;    // 최종 FND 데이터 (0~9999)

    
    // ========================================
    // State Register
    // ========================================
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            c_state <= WAIT_HIGH_BYTE;
            high_byte_reg <= 8'd0;
            fnd_data_reg <= 14'd0;
        end else begin
            c_state <= n_state;
            high_byte_reg <= high_byte_next;
            fnd_data_reg <= fnd_data_next;
        end
    end


    // ========================================
    // Next State Logic + Output Logic (Combinational)
    // ========================================
    always_comb begin
        // 기본값 설정 (Latch 방지)
        n_state = c_state;
        high_byte_next = high_byte_reg;
        fnd_data_next = fnd_data_reg;
        
        case(c_state)
            WAIT_HIGH_BYTE: begin
                // 첫 번째 바이트 (상위) 수신 대기
                if (done) begin
                    n_state = WAIT_LOW_BYTE;
                    high_byte_next = rx_data;       // 상위 바이트 저장 (0~99)
                    fnd_data_next = fnd_data_reg;   // FND 데이터 유지
                end else begin
                    n_state = WAIT_HIGH_BYTE;
                end
            end

            WAIT_LOW_BYTE: begin
                // 두 번째 바이트 (하위) 수신 대기
                if (done) begin
                    n_state = UPDATE_DISPLAY;
                    
                    // *** 핵심 연산: (high × 100) + low ***
                    // high_byte_reg: 0~99 (100의 자리)
                    // rx_data:       0~99 (1의 자리)
                    fnd_data_next = (high_byte_reg * 100) + rx_data;
                    
                    // 안전장치: 9999 초과 시 wrapping
                    if (fnd_data_next == 14'd9999) begin
                        fnd_data_next = 14'd0;
                    end
                    
                    high_byte_next = 8'd0;  // 사용 완료
                end else begin
                    n_state = WAIT_LOW_BYTE;
                end
            end

            UPDATE_DISPLAY: begin
                // 디스플레이 업데이트 완료, 다음 데이터 대기
                n_state = WAIT_HIGH_BYTE;
            end

            default: begin
                n_state = WAIT_HIGH_BYTE;
                high_byte_next = 8'd0;
                fnd_data_next = 14'd0;
            end
        endcase
    end
    
    // ========================================
    // 출력
    // ========================================
    assign fnd_data = fnd_data_reg;

endmodule


// 10000진 couunter
module fnd_controller(
    input [13:0] i_fnd_data,
    input  clk,
    input  rst,
    output [6:0] o_fnd_data,
    output [3:0] fnd_com
    );

    wire [3:0] w_digit_1;
    wire [3:0] w_digit_10;
    wire [3:0] w_digit_100;
    wire [3:0] w_digit_1000;
    wire [3:0] w_bcd;
    wire [1:0] w_digit_sel;

    wire w_1khz;


    digit_spliter U_DS(
        .i_data(i_fnd_data),  
        .digit_1(w_digit_1),
        .digit_10(w_digit_10),
        .digit_100(w_digit_100),
        .digit_1000(w_digit_1000)
    );

    bcd_decoder U_BCD(
        .bcd(w_bcd),
        .fnd_data(o_fnd_data)
    );


    mux_4x1 U_MUX4_1(
        .sel(w_digit_sel),
        .digit_1(w_digit_1),
        .digit_10(w_digit_10),
        .digit_100(w_digit_100),
        .digit_1000(w_digit_1000),
        .bcd_data(w_bcd)
    );
    
    mux_2x4 U_Mux_Fnd_com(
        .sel(w_digit_sel),
        .fnd_com(fnd_com)
    );

    counter_4 U_CNT_4(
        .clk(w_1khz),
        .rst(rst),
        .digit_sel(w_digit_sel)
    );

    clk_div U_CLK_DIV(
        .clk(clk),
        .rst(rst),
        .o_1khz(w_1khz)
    );

endmodule



module digit_spliter(
    input [13:0] i_data,   // 8bit筌욎뮆?봺 sov_e + cov
    
    output [3:0] digit_1,
    output [3:0] digit_10,
    output [3:0] digit_100,
    output [3:0] digit_1000
);

    assign digit_1 = i_data % 10;
    assign digit_10 = i_data/10 % 10;
    assign digit_100 = i_data/100 % 10;
    assign digit_1000 = i_data/1000 % 10;

endmodule


module bcd_decoder(
    input [3:0]bcd,
    output reg [6:0]fnd_data  
);

    always @(bcd) begin
        case(bcd)
            0 : fnd_data =  7'h40;  // 7-bit: 1000000 (segments a,b,c,d,e,f)
            1 : fnd_data =  7'h79;  // 7-bit: 1111001 (segments b,c)
            2 : fnd_data =  7'h24;  // 7-bit: 0100100 (segments a,b,g,e,d)
            3 : fnd_data =  7'h30;  // 7-bit: 0110000 (segments a,b,g,c,d)
            4 : fnd_data =  7'h19;  // 7-bit: 0011001 (segments f,g,b,c)
            5 : fnd_data =  7'h12;  // 7-bit: 0010010 (segments a,f,g,c,d)
            6 : fnd_data =  7'h02;  // 7-bit: 0000010 (segments a,f,g,e,d,c)
            7 : fnd_data =  7'h78;  // 7-bit: 1111000 (segments a,b,c)
            8 : fnd_data =  7'h00;  // 7-bit: 0000000 (all segments)
            9 : fnd_data =  7'h10;  // 7-bit: 0010000 (segments a,b,c,d,f,g)
            default : fnd_data = 7'h7f; // 7-bit: all off
        endcase
    end

endmodule



module mux_4x1(
    input [1:0] sel,
    input [3:0]digit_1,
    input [3:0]digit_10,
    input [3:0]digit_100,        
    input [3:0]digit_1000,    
    output reg [3:0] bcd_data
    );


    always @(*) begin
        case(sel)
            2'b00 : bcd_data = digit_1;
            2'b01 : bcd_data = digit_10;
            2'b10 : bcd_data = digit_100;
            2'b11 : bcd_data = digit_1000;
            default : bcd_data = digit_1;
        endcase
     end    

endmodule

module mux_2x4(
        input [1:0] sel,
        output reg [3:0] fnd_com
    );

    always @(sel) begin
        case(sel)
            2'b00 : fnd_com = 4'b1110;
            2'b01 : fnd_com = 4'b1101;
            2'b10 : fnd_com = 4'b1011;
            2'b11 : fnd_com = 4'b0111;
            default : fnd_com = 4'b1111;
        endcase
    end

    


endmodule

module counter_4(
    input clk,
    input rst,
    output [1:0] digit_sel
    );

    reg [1:0] r_counter;

    assign digit_sel = r_counter;

    always@(posedge clk or posedge rst)begin
        if(rst) begin
            r_counter <= 2'b00;
        end
        else begin
            r_counter <= r_counter + 1'b1;
        end
    end
    
endmodule


module clk_div(
    input clk,
    input rst,
    output reg o_1khz
    );

    reg [16:0]r_counter;

always @(posedge clk or posedge rst)begin
    if(rst) begin
        r_counter <= 0;
        o_1khz <= 0;
    end 
    else begin
    if(r_counter == 100_000-1 ) begin
        r_counter <= 0;
        o_1khz <= 1'b1;
    end
    else begin
        r_counter <= r_counter + 1'b1;
        o_1khz <= 0;
        end
    end
end

endmodule
