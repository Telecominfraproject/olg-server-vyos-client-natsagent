package config

import "strings"

const redactedValue = "********"

func (c AppConfig) Redacted() AppConfig {
	out := c

	out.AgentCore.NATS.Password = redactString(out.AgentCore.NATS.Password)
	out.AgentCore.NATS.Token = redactString(out.AgentCore.NATS.Token)
	out.AgentCore.NATS.CredentialsFile = redactString(out.AgentCore.NATS.CredentialsFile)
	out.AgentCore.NATS.NKeySeedFile = redactString(out.AgentCore.NATS.NKeySeedFile)
	out.AgentCore.NATS.UserJWTFile = redactString(out.AgentCore.NATS.UserJWTFile)
	out.AgentCore.NATS.TLS.KeyFile = redactString(out.AgentCore.NATS.TLS.KeyFile)
	out.AgentCore.NATS.TLS.CertFile = redactString(out.AgentCore.NATS.TLS.CertFile)
	out.AgentCore.NATS.TLS.CAFile = redactString(out.AgentCore.NATS.TLS.CAFile)

	return out
}

func redactString(v string) string {
	if strings.TrimSpace(v) == "" {
		return ""
	}
	return redactedValue
}
