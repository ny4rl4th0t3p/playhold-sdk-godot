## The frames Godobuf generates, against bytes encoded by hand from playhold's frames.proto, the way Go's protobuf
## encodes them: fields in number order, proto3 defaults left out.
extends GutTest

const Frames = preload("res://addons/playhold/frames.gd")


func _client_frame(seq: int) -> Frames.ClientFrame:
	var frame := Frames.ClientFrame.new()
	frame.set_seq(seq)
	return frame


func _decode(hex: String) -> Frames.ServerFrame:
	var frame := Frames.ServerFrame.new()
	assert_eq(frame.from_bytes(hex.hex_decode()), Frames.PB_ERR.NO_ERRORS, "from_bytes " + hex)
	return frame


## Asserts the frame's body case, and says whether to go on reading it.
func _is_case(frame: Frames.ServerFrame, want: int) -> bool:
	assert_eq(frame.get_body_case(), want, "body case")
	return frame.get_body_case() == want


func test_encode_hello_with_a_map() -> void:
	var frame := _client_frame(1)
	var hello := frame.new_hello()
	hello.set_protocol_version(1)
	hello.add_schema_versions("tictactoe", 2)
	assert_eq(frame.to_bytes().hex_encode(), "080112110801220d0a09746963746163746f651002")


func test_encode_join_with_an_empty_code() -> void:
	var frame := _client_frame(5)
	frame.new_join() # an empty code asks for a new room, so the empty Join must still be sent
	assert_eq(frame.to_bytes().hex_encode(), "08051a00")


func test_encode_leave_queue_an_empty_message() -> void:
	var frame := _client_frame(2)
	frame.new_leave_queue()
	assert_eq(frame.to_bytes().hex_encode(), "08023200")


func test_encode_module_message_with_bytes() -> void:
	var frame := _client_frame(3)
	var message := frame.new_module_message()
	message.set_module("board")
	message.set_id(1)
	message.set_payload(PackedByteArray([0x08, 0x04]))
	assert_eq(frame.to_bytes().hex_encode(), "0803220d0a05626f61726410011a020804")


func test_encode_queue_with_a_string_map() -> void:
	var frame := _client_frame(4)
	frame.new_queue().add_properties("mode", "fast")
	assert_eq(frame.to_bytes().hex_encode(), "08042a0e0a0c0a046d6f6465120466617374")


func test_encode_a_second_case_replaces_the_first() -> void:
	var frame := _client_frame(6)
	frame.new_hello().set_protocol_version(1)
	frame.new_join().set_code("ABCD")
	assert_eq(frame.to_bytes().hex_encode(), "08061a060a0441424344")


func test_decode_welcome() -> void:
	var frame := _decode("0a070a027031120173")
	if _is_case(frame, Frames.ServerFrame.BodyCase.WELCOME):
		assert_eq(frame.get_welcome().get_player_id(), "p1")
		assert_eq(frame.get_welcome().get_secret(), "s")


func test_decode_welcome_with_every_field_empty() -> void:
	var frame := _decode("0a00")
	if _is_case(frame, Frames.ServerFrame.BodyCase.WELCOME):
		assert_eq(frame.get_welcome().get_player_id(), "")
		assert_eq(frame.get_welcome().get_secret(), "")


func test_decode_room_state_with_two_views() -> void:
	var frame := _decode("12120a070a016d120201020a070a016e12020304")
	if _is_case(frame, Frames.ServerFrame.BodyCase.STATE):
		var views := frame.get_state().get_views()
		assert_eq(views.size(), 2)
		if views.size() == 2:
			assert_eq(views[0].get_module(), "m")
			assert_eq(views[0].get_view(), PackedByteArray([1, 2]))
			assert_eq(views[1].get_module(), "n")
			assert_eq(views[1].get_view(), PackedByteArray([3, 4]))


func test_decode_server_error() -> void:
	var frame := _decode("1a070805100f1a0178")
	if _is_case(frame, Frames.ServerFrame.BodyCase.ERROR):
		var error := frame.get_error()
		assert_eq(error.get_seq(), 5)
		assert_eq(error.get_code(), Frames.ErrorCode.ROOM_NOT_FOUND)
		assert_eq(error.get_text(), "x")


func test_decode_a_two_byte_varint() -> void:
	var frame := _decode("1a0308ac02")
	if _is_case(frame, Frames.ServerFrame.BodyCase.ERROR):
		assert_eq(frame.get_error().get_seq(), 300)


func test_decode_an_error_code_this_client_does_not_know() -> void:
	var frame := _decode("1a021063")
	if _is_case(frame, Frames.ServerFrame.BodyCase.ERROR):
		assert_eq(frame.get_error().get_code(), 99)


func test_decode_room_closed() -> void:
	var frame := _decode("22020806")
	if _is_case(frame, Frames.ServerFrame.BodyCase.CLOSED):
		assert_eq(frame.get_closed().get_reason(), Frames.CloseReason.MATCH_INCOMPLETE)


func test_decode_joined() -> void:
	var frame := _decode("2a080807120441424344")
	if _is_case(frame, Frames.ServerFrame.BodyCase.JOINED):
		assert_eq(frame.get_joined().get_seq(), 7)
		assert_eq(frame.get_joined().get_code(), "ABCD")


func test_decode_queued() -> void:
	var frame := _decode("32020808")
	if _is_case(frame, Frames.ServerFrame.BodyCase.QUEUED):
		assert_eq(frame.get_queued().get_seq(), 8)


func test_decode_matched() -> void:
	var frame := _decode("3a060a045758595a")
	if _is_case(frame, Frames.ServerFrame.BodyCase.MATCHED):
		assert_eq(frame.get_matched().get_code(), "WXYZ")


func test_decode_a_utf8_string() -> void:
	var frame := _decode("3a040a02c3a9")
	if _is_case(frame, Frames.ServerFrame.BodyCase.MATCHED):
		assert_eq(frame.get_matched().get_code(), "é")


func test_decode_skips_an_unknown_field() -> void:
	_is_case(_decode("48010a00"), Frames.ServerFrame.BodyCase.WELCOME)


func test_decode_leaves_a_frame_type_a_newer_server_adds_unset() -> void:
	_is_case(_decode("4200"), Frames.ServerFrame.BodyCase.BODY_NOT_SET)


func test_decode_a_truncated_frame_is_an_error() -> void:
	var frame := Frames.ServerFrame.new()
	assert_ne(frame.from_bytes("0a070a".hex_decode()), Frames.PB_ERR.NO_ERRORS)