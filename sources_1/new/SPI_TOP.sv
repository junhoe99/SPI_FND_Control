`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/11/07 16:45:42
// Design Name: 
// Module Name: SPI_TOP
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


module SPI_TOP(
    // Global Signals
    input logic clk,
    input logic reset,
    // Button Interface
    input logic run_stop,
    input logic clear,
    // FND Interface
    output logic [6:0] fnd_data,
    output logic [3:0] fnd_com,
    // SPI Interface - Master Output (to external Slave)
    output logic o_SCLK,
    output logic o_MOSI,
    output logic o_SS_N,
    // SPI Interface - Slave Input (from external Master)
    input logic i_SCLK,
    input logic i_MOSI,
    input logic i_SS_N,
    input logic i_MISO,
    // SPI Interface - Slave Output (to external Master)
    output logic o_MISO
    );

    // Internal Master signals
    logic w_master_sclk;
    logic w_master_mosi;
    logic w_master_ss_n;
    logic w_master_miso;
    logic db_run_stop; // Not connected
    logic db_clear;    // Not connected

    // Instantiation
    Master U_Master (
        .clk(clk),
        .reset(reset),
        .run_stop(db_run_stop), // Debounced button output
        .clear(db_clear),
        .o_SCLK(w_master_sclk),
        .o_MOSI(w_master_mosi),
        .o_SS_N(w_master_ss_n),
        .i_MISO(w_master_miso)
    );

    Slave U_Slave (
        .clk(clk),
        .reset(reset),
        .i_SCLK(i_SCLK),
        .i_MOSI(i_MOSI),
        .i_SS_N(i_SS_N),
        .o_MISO(o_MISO),
        .fnd_data(fnd_data),
        .fnd_com(fnd_com)
    );

    btn_debounce U_RUN_DEBOUNCE (
        .clk(clk),
        .reset(reset),
        .i_btn(run_stop),
        .o_btn(db_run_stop) // Not connected
    );

    btn_debounce U_CLEAR_DEBOUNCE (
        .clk(clk),
        .reset(reset),
        .i_btn(clear),
        .o_btn(db_clear) // Not connected
    );
    
    // Master outputs to external pins
    assign o_SCLK = w_master_sclk;
    assign o_MOSI = w_master_mosi;
    assign o_SS_N = w_master_ss_n;
    assign w_master_miso = i_MISO;

endmodule



module btn_debounce(
    input clk,
    input reset,
    input i_btn,
    output o_btn
    );

    wire debounce;
    reg [3:0] q_reg, q_next;



    //clk divider 100MHz -> 1MHz. Reinforcing bouncing circuit
    reg [($clog2(100)-1):0] counter;
    reg r_db_clk;


    always @(posedge clk or posedge reset) begin
        if(reset) begin
            counter <= 0;
            r_db_clk <= 0;
        end 
        else begin                 
            if(counter == (100-1)) begin
                counter <= 0;
                r_db_clk <= 1'b1; // 1MHz clock
            end
            else begin
                counter <= counter + 1;
                r_db_clk <= 1'b0;
            end
        end
    end
    
    
    
    
    //shift register 
    always @(posedge r_db_clk or posedge reset) begin
        if(reset) begin
            q_reg <= 0;
        end else begin
            q_reg <= q_next;
        end
        
    end

    always @(*)begin
        q_next = {i_btn, q_reg[3:1]};
    end
 

    // Edge detection logic
    assign debounce = &q_reg;

    reg edge_reg;

    always @(posedge clk or posedge reset) begin
        if(reset) begin
            edge_reg <= 0;
        end else begin
            edge_reg <= debounce;
        end
    end


    // Output logic
    assign o_btn = ~edge_reg & debounce;
endmodule
