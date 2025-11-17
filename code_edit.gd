extends CodeEdit

func _request_code_completion(force: bool):    
	add_code_completion_option(CodeEdit.KIND_VARIABLE, "test", "test")
	add_code_completion_option(CodeEdit.KIND_VARIABLE, "testa", "testa")
	update_code_completion_options(true)
