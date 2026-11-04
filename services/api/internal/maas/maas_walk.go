package maas

import "fmt"

func walkInstruction(maneuverType, modifier, name string) string {
	switch maneuverType {
	case "arrive":
		return "抵達目的地"
	case "depart":
		if name != "" {
			return fmt.Sprintf("沿%s出發", name)
		}
		return "開始步行"
	}
	return walkTurnInstruction(modifier, name)
}

func walkTurnInstruction(modifier, name string) string {
	turn := map[string]string{
		"left": "左轉", "right": "右轉",
		"slight left": "稍向左", "slight right": "稍向右",
		"sharp left": "向左急轉", "sharp right": "向右急轉",
		"uturn": "迴轉",
	}[modifier]
	if turn != "" {
		return namedWalkTurn(turn, name)
	}
	if name != "" {
		return fmt.Sprintf("沿%s直走", name)
	}
	return "繼續直走"
}

func namedWalkTurn(turn, name string) string {
	if name != "" {
		return fmt.Sprintf("%s進入%s", turn, name)
	}
	return turn
}
