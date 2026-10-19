package installid

import "strings"

func ParseBearerCredential(header string) string {
	if !trimmedBearerHeader(header) {
		return ""
	}
	separator, ok := bearerSeparator(header)
	if !ok {
		return ""
	}
	return bearerValue(header[separator:])
}

func trimmedBearerHeader(header string) bool {
	return header != "" && header == strings.TrimSpace(header)
}

func bearerSeparator(header string) (int, bool) {
	separator := strings.IndexAny(header, " \t")
	if separator == -1 || !strings.EqualFold(header[:separator], "Bearer") {
		return 0, false
	}
	return separator, true
}

func bearerValue(value string) string {
	credential := strings.TrimLeft(value, " \t")
	if credential == "" || strings.ContainsAny(credential, " \t\r\n") {
		return ""
	}
	return credential
}

// HTTPPort is the only port the router's HTTP server ever serves on, so a
// self-referential URL (the GBFS discovery document) can name it without a
// config setting.
const HTTPPort = "8080"
