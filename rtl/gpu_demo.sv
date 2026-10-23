`timescale 1ns/1ps
// Boot -> render -> transmit completed frame repeatedly. Header: GPU2,
// width=64, height=64, threads=32, warp error bitmap; then 4096 LE32 pixels.
module gpu_demo #(parameter UART_DIV=87, FRAME_GAP=10000000)(
    input wire clk, reset, output wire uart_tx_o, output wire [1:0] led
);
    reg launched;
    wire busy, done;
    wire [3:0] error;
    wire [31:0] cycles, pixel;
    reg [14:0] pos;
    reg [31:0] gap;
    wire [14:0] payload=pos-15'd8;
    wire [31:0] host_word={19'b0,payload[14:2]};
    wire ready;
    wire valid=done && (gap==0);
    reg [7:0] tx_data;
    compute_gpu gpu(.clk(clk),.reset(reset),.start(!launched && !reset),
        .busy(busy),.done(done),.error(error),.cycles(cycles),
        .host_word(host_word),.host_rdata(pixel));
    always @* begin
        case(pos)
            0: tx_data="G"; 1: tx_data="P"; 2: tx_data="U"; 3: tx_data="2";
            4: tx_data=64; 5: tx_data=64; 6: tx_data=32; 7: tx_data={4'b0,error};
            default: tx_data=pixel >> {payload[1:0],3'b0};
        endcase
    end
    uart_tx #(.DIV(UART_DIV)) serial(.clk(clk),.reset(reset),.valid(valid),
        .data(tx_data),.ready(ready),.tx(uart_tx_o));
    always @(posedge clk) begin
        if(reset) begin launched<=0; pos<=0; gap<=0; end
        else begin
            launched<=1;
            if(gap!=0) gap<=gap-1;
            if(valid && ready) begin
                if(pos==16391) begin pos<=0; gap<=FRAME_GAP; end
                else pos<=pos+1;
            end
        end
    end
    assign led={|error,done && !(|error)};
endmodule
