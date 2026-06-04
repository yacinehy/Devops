from flask import Flask, jsonify, request

app = Flask(__name__)


@app.route("/")
def index():
    return jsonify({"message": "Hello DevOps", "status": "ok"})


@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200


@app.route("/api/hello")
def hello():
    name = request.args.get("name", "World")
    return jsonify({"message": f"Hello {name}"})


@app.route("/api/status")
def status():
    return jsonify({"version": "1.0.0", "uptime": "ok"})


if __name__ == "__main__":
    app.run(debug=True)
