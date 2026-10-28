use strict;
use warnings;
use Test::More;
use t::Util;

plan skip_all => "h2get not found"
    unless h2get_exists();

# A request body that is larger than the limit makes h2o reset the stream. The client might have already sent trailers by then;
# h2o has to ignore them without closing the connection, and without losing sync of the HPACK state. The latter is checked by sending
# a request that refers to the header added to the HPACK dynamic table by the trailers.
my $server = spawn_h2o(<< "EOT");
limit-request-body: 10
hosts:
  default:
    paths:
      "/":
        file.dir: @{[ DOC_ROOT ]}
EOT

# The trailers are encoded by hand: literal header field with incremental indexing ("x-trailer: 1"), which adds an entry to the
# HPACK dynamic table of the connection, so that the entry can be referred to by the request sent afterwards.
my %trailer_frames = (
    "single HEADERS frame" => 'h2g.send_raw_frame(1, 1, END_STREAM | END_HEADERS, "\x40\x09x-trailer\x011")',
    "HEADERS and CONTINUATION" => 'h2g.send_raw_frame(1, 1, END_STREAM, "\x40\x09x-tr")' . "\n" .
                                  'h2g.send_raw_frame(1, 9, END_HEADERS, "ailer\x011")',
);

for my $name (sort keys %trailer_frames) {
    subtest $name => sub {
        my ($stderr, $stdout) = run_with_h2get_simple($server, <<"EOR");
req = { ":method" => "POST", ":authority" => authority, ":scheme" => "https", ":path" => "/index.txt" }
h2g.send_headers(req, 1, END_HEADERS)
h2g.send_data(1, 0, "x" * 100)
reset = false
while (f = h2g.read(1000)) != nil
    if f.type == "RST_STREAM" and f.stream_id == 1 then
        reset = true
        break
    end
end
puts "reset-before-trailers=#{reset}"

$trailer_frames{$name}

# GET, https, "/", :authority as a literal, and index 62 (the first entry of the dynamic table: "x-trailer: 1")
h2g.send_raw_frame(3, 1, END_STREAM | END_HEADERS, "\x82\x87\x84\x01" + authority.length.chr + authority + "\xbe")
goaway = false
completed = false
while (f = h2g.read(2000)) != nil
    if f.type == "GOAWAY" then
        goaway = true
        break
    end
    if f.stream_id == 3 and (f.type == "HEADERS" or f.type == "DATA") and f.is_end_stream then
        completed = true
        break
    end
end
puts "goaway=#{goaway}"
puts "stream3-completed=#{completed}"
EOR
        like $stdout, qr/^reset-before-trailers=true$/m, "stream is reset before the trailers are sent";
        unlike $stdout, qr/^goaway=true$/m, "connection is kept open";
        like $stdout, qr/^stream3-completed=true$/m, "later request that uses the HPACK entry from the trailers succeeds";
    };
}

done_testing;