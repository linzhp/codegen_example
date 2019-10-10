package main

import (
	"encoding/json"
	"flag"
	"html/template"
	"io/ioutil"
	"log"
	"os"
)

func main() {
	pkg := flag.String("package", "codegen", "the package name in the generated code file")
	tmplPath := flag.String("tmpl", "factory/templates/things.tmpl", "the template file")
	configPath := flag.String("config", "factory/config/base.json", "the configuration file")
	outPath := flag.String("out", "out.go", "the output file")
	flag.Parse()
	file, err := os.Open(*configPath)
	check(err)
	decoder := json.NewDecoder(file)
	var config Configuration
	if err = decoder.Decode(&config); err != nil {
		log.Fatal(err)
	}
	config.Package = *pkg

	rawBytes, err := ioutil.ReadFile(*tmplPath)
	check(err)
	tmpl, err := template.New("thing").Parse(string(rawBytes))
	check(err)
	out, err := os.Create(*outPath)
	check(err)
	err = tmpl.Execute(out, config)
	check(err)
}

type Configuration struct {
	Package  string
	Count    int
	Material string
}

func check(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
