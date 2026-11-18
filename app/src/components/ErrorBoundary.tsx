import { Component, type ReactNode } from 'react';

// A screen that throws shows a way out instead of a blank page.
export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="card bad stack" style={{ margin: 16 }}>
        <h2>Something went wrong on this screen</h2>
        <p className="small">{this.state.error.message}</p>
        <div className="row">
          <button className="btn" onClick={() => { this.setState({ error: null }); location.hash = '#/'; }}>Go home</button>
          <button className="btn secondary" onClick={() => location.reload()}>Reload</button>
        </div>
      </div>
    );
  }
}
