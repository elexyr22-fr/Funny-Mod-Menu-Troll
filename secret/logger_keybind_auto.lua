if SecretAuto and SecretAuto.start then
	if SecretAuto.active then
		SecretAuto:stop("keybind STOP")
	else
		SecretAuto:start()
	end
else
	log("[SecretAuto] secret_auto.lua not loaded")
end
